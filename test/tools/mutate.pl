#!/usr/bin/env perl
# Mutation-test the procs marked `// mull-on` against the test:all suite.
#
#     test/tools/mutate.pl [-v]        # -v also lists killed mutants
#
# MUTATE_DEBUG=1 prints the compiler output of each round.
#
# ast-grep (with the tree-sitter-odin grammar) runs the rules in mutants.yml:
# `body` finds each marked proc's block, and every other rule's matches with
# their fixes inside a marked block are the mutants. Instead of rebuilding per
# mutant, every mutant becomes a branch of the body:
#
#     name :: proc(...) -> ... {
#     if __mut == 1 {<block with mutant 1>} else if __mut == 2 {...}
#     else {<original block>}
#     }
#
# and a generated file per package sets __mut from $MUTANT at startup. The
# suite is built once and run once per mutant. Mutants that do not compile are
# dropped using the compiler's error lines. The worktree is never written.
use v5.36;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $GRAMMAR_REPO = 'https://github.com/tree-sitter-grammars/tree-sitter-odin';
my $GRAMMAR_REV  = 'd2ca8efb4487e156a60d5bd6db2598b872629403';
my @BUILD = ('odin', 'build', 'test/', '-build-mode:test', '-all-packages', '-debug');
my $verbose = @ARGV && $ARGV[0] eq '-v';

sub slurp ($path) {
	open my $fh, '<:raw', $path or die "mutate: $path: $!\n";
	local $/;
	return <$fh>;
}

sub spew ($path, $text) {
	open my $fh, '>:raw', $path or die "mutate: $path: $!\n";
	print $fh $text;
}

chdir abs_path(dirname(__FILE__) . '/../..') or die "mutate: chdir: $!\n";
my $root = abs_path('.');
my ($sg) = grep { -x } $ENV{AST_GREP} // (), '/tmp/sgvenv/bin/ast-grep', map {"$_/ast-grep"} split /:/, $ENV{PATH};
die "mutate: ast-grep not found; see test/tools/MUTATION.md\n" unless $sg;

# The Odin grammar, built once into .test-data/ (gitignored).
my $grammar = "$root/.test-data/odin.so";
unless (-e $grammar) {
	my $src = "$root/.test-data/tree-sitter-odin";
	say STDERR "mutate: building $grammar";
	system("rm -rf '$src' && git init -q '$src' && git -C '$src' fetch -q --depth 1 '$GRAMMAR_REPO' $GRAMMAR_REV"
			. " && git -C '$src' checkout -q FETCH_HEAD"
			. " && cc -shared -fPIC -O2 -I'$src/src' '$src/src/parser.c' '$src/src/scanner.c' -o '$grammar'") == 0
		or die "mutate: could not build the tree-sitter-odin grammar\n";
}

my $work = tempdir('booru-mutate-XXXXXXXX', TMPDIR => 1);
my $tree = "$work/tree";
say STDERR "mutate: scratch dir $work";
system("git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- . '$tree'") == 0
	or die "mutate: copy failed\n";
spew("$work/sgconfig.yml", "customLanguages:\n  odin:\n    libraryPath: $grammar\n    extensions: [odin]\n    expandoChar: _\n");
chdir $tree or die "mutate: chdir: $!\n";

# 1. Marked blocks and mutants, as byte ranges. A block includes its braces.
my (%src, @bodies, @matches);
open my $scan, '-|', $sg, 'scan', '--config', "$work/sgconfig.yml", '--custom-languages', 'allow',
	'--rule', "$root/test/tools/mutants.yml", '--json=stream', 'src'
	or die "mutate: ast-grep: $!\n";
while (<$scan>) {
	my $m = decode_json($_);
	my ($file, $r) = ($m->{file}, $m->{range}{byteOffset});
	$src{$file} //= slurp($file);
	if ($m->{ruleId} eq 'body') {
		my @names = substr($src{$file}, 0, $r->{start}) =~ /^(\w+) :: proc\b/mg;
		push @bodies, { file => $file, name => $names[-1] // '?', start => $r->{start}, end => $r->{end} };
	} elsif (defined $m->{replacement}) {
		my $at = $m->{replacementOffsets} // $r;
		push @matches, { file => $file, rule => $m->{ruleId}, start => $at->{start}, end => $at->{end}, new => $m->{replacement} };
	}
}
close $scan or die "mutate: ast-grep scan failed\n";
die "mutate: no // mull-on procs under src/\n" unless @bodies;

my %mutants;    # id -> { body, rule, start, end, new }
my ($next_id, %seen) = (1);
for my $m (sort { $a->{file} cmp $b->{file} || $a->{start} <=> $b->{start} } @matches) {
	my ($body) = grep { $_->{file} eq $m->{file} && $_->{start} <= $m->{start} && $m->{end} <= $_->{end} } @bodies
		or next;
	next if $seen{"$m->{file} $m->{start} $m->{end} $m->{new}"}++;
	$mutants{ $next_id++ } = { %$m, body => $body };
}
say STDERR 'mutate: ', scalar(keys %mutants), ' mutants in ', join(', ', map { $_->{name} } @bodies);

# 3. Write the switched bodies; build; drop mutants the compiler rejects.
sub write_tree {
	my %where;    # "file line" (1-based, rewritten file) -> mutant id
	my %by_file;
	push @{ $by_file{ $_->{file} } }, $_ for @bodies;
	for my $file (keys %by_file) {
		my $text = $src{$file};
		my ($out, $at) = ('', 0);
		my $mark = sub ($id, $added) {    # map every line of the text just added
			my $line = ($out =~ tr/\n//) + 1;
			my $from = $line - ($added =~ tr/\n//);
			$where{"$file $_"} = $id for $from .. $line;
		};
		for my $body_at (sort { $a->{start} <=> $b->{start} } @{ $by_file{$file} }) {
			$out .= substr($text, $at, $body_at->{start} - $at);
			my $body = substr($text, $body_at->{start}, $body_at->{end} - $body_at->{start});
			my $prev;
			for my $id (sort { $a <=> $b } grep { $mutants{$_}{body} == $body_at } keys %mutants) {
				my $m = $mutants{$id};
				my $mutated = $body;
				substr($mutated, $m->{start} - $body_at->{start}, $m->{end} - $m->{start}) = $m->{new};
				my $branch = ($prev ? ' else ' : "{\n") . "if __mut == $id $mutated";
				$out .= $branch;
				$mark->($id, $branch);
				$prev = $id;
			}
			if ($prev) {
				$out .= ' else ';
				$mark->($prev, '');    # a brace a mutant broke shows up here
			}
			$out .= $body;
			$out .= "\n}" if $prev;
			$at = $body_at->{end};
		}
		$out .= substr($text, $at);
		spew($file, $out);
		my ($pkg) = $text =~ /^package (\w+)/m;
		spew(dirname($file) . '/zz_mutate_switch.odin', <<~"ODIN");
			package $pkg

			import __mutate_rt "base:runtime"
			import __mutate_os "core:os"
			import __mutate_strconv "core:strconv"

			\@(private = "package")
			__mut: int

			\@(init, private = "file")
			__mutate_init :: proc "contextless" () {
				context = __mutate_rt.default_context()
				buf: [32]u8
				__mut, _ = __mutate_strconv.parse_int(__mutate_os.get_env(buf[:], "MUTANT"))
			}
			ODIN
	}
	return \%where;
}

my $exe = "$work/test-all";
for (my $round = 1;; $round++) {
	my $where = write_tree();
	my $out = `@BUILD -error-pos-style:unix -max-error-count:10000 -out:'$exe' 2>&1`;
	last if $? == 0;
	print STDERR $out if $ENV{MUTATE_DEBUG};
	my %bad;
	while ($out =~ m{^(\S+?):(\d+):\d+:\s*(?:Syntax\s+)?Error}mg) {
		my ($path, $line) = ($1, $2);
		my $file = $path =~ s{^\Q$tree\E/}{}r;
		my $id = $where->{"$file $line"} or die "$out\nmutate: build error outside any mutant ($file:$line)\n";
		$bad{$id} = 1;
	}
	die "$out\nmutate: build failed\n" unless %bad;
	delete @mutants{ keys %bad };
	say STDERR "mutate: round $round dropped ", scalar(keys %bad), ' mutants that do not compile';
	die "mutate: every mutant failed to compile\n" unless %mutants;
}

# 4. Baseline, then one run per mutant. A failing or timed-out run kills it.
my $t0 = time;
system("MUTANT=0 '$exe' >/dev/null 2>&1") == 0 or die "mutate: test:all fails without mutants\n";
my $timeout = 10 * (time - $t0 + 1);
my (@survived, @killed);
for my $id (sort { $a <=> $b } keys %mutants) {
	my $rc = system("MUTANT=$id timeout $timeout '$exe' >/dev/null 2>&1") >> 8;
	push @{ $rc == 0 ? \@survived : \@killed }, $id;
}

# 5. Report: file:line:col, the original text and its replacement.
sub show ($status, $id) {
	my $m    = $mutants{$id};
	my $text = $src{ $m->{body}{file} };
	my $before = substr($text, 0, $m->{start});
	my $line = ($before =~ tr/\n//) + 1;
	my $col  = $m->{start} - (rindex($before, "\n") + 1) + 1;
	my $orig = substr($text, $m->{start}, $m->{end} - $m->{start}) =~ s/\s+/ /gr;
	my $new  = $m->{new} =~ s/\s+/ /gr;
	$orig = substr($orig, 0, 60) . '...' if length $orig > 63;
	say "$m->{body}{file}:$line:$col: $status: [$m->{rule}] `$orig` => `$new`";
}
my $by_pos = sub { $mutants{$a}{body}{file} cmp $mutants{$b}{body}{file} || $mutants{$a}{start} <=> $mutants{$b}{start} || $a <=> $b };
show('killed', $_) for $verbose ? sort $by_pos @killed : ();
show('SURVIVED', $_) for sort $by_pos @survived;
my $total = @killed + @survived;
printf "mutate: %d/%d killed (%.0f%%)\n", scalar @killed, $total, 100 * @killed / $total;
exit(@survived ? 1 : 0);
