#!/usr/bin/env perl
# Mutation-test the procs marked `// mull-on` against the test:all suite.
#
#     test/tools/mutate.pl [-v]        # -v also lists killed mutants
#
# MUTATE_DEBUG=1 prints the compiler output of each round.
#
# universalmutator generates one-line source mutants of each marked proc body.
# Instead of rebuilding per mutant, every mutant becomes a branch of the body:
#
#     name :: proc(...) -> ... {
#     if __mut == 1 {
#         <body with mutant 1's line>
#     } else if __mut == 2 {
#         ...
#     } else {
#         <original body>
#     }
#     }
#
# and a generated file per package sets __mut from $MUTANT at startup. The
# suite is built once and run once per mutant. Mutants that do not compile are
# dropped using the compiler's error lines. Only text is rewritten: the body
# is found by odinfmt's layout (signature ends in `{`, the proc ends at the
# next `}` in column 0), so the tree must be odinfmt-clean (the pre-commit
# hook checks this). The worktree is never written.
use v5.36;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $MUTATE = $ENV{UNIVERSALMUTATOR} // '/tmp/umvenv/bin/mutate';
my @BUILD  = ('odin', 'build', 'test/', '-build-mode:test', '-all-packages', '-debug');
my $verbose = @ARGV && $ARGV[0] eq '-v';

sub slurp ($path) {
	open my $fh, '<', $path or die "mutate: $path: $!\n";
	return [<$fh>];
}

sub spew ($path, @lines) {
	open my $fh, '>', $path or die "mutate: $path: $!\n";
	print $fh @lines;
}

die "mutate: missing $MUTATE; see test/tools/MUTATION.md\n" unless -x $MUTATE;
chdir abs_path(dirname(__FILE__) . '/../..') or die "mutate: chdir: $!\n";
my $rules = abs_path('test/tools/odin.rules');
my $work  = tempdir('booru-mutate-XXXXXXXX', TMPDIR => 1);
my $tree  = "$work/tree";
say STDERR "mutate: scratch dir $work";
system("git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- . '$tree'") == 0
	or die "mutate: copy failed\n";
my @sources = split /\0/, `git ls-files -co --exclude-standard -z 'src/*.odin'`;
chdir $tree or die "mutate: chdir: $!\n";

# 1. Marked procs: `// mull-on`, optional attribute lines, `name :: proc`,
#    body from after the line ending in `{` to before the next `}` line.
my @procs;    # { file, name, open, close } with 0-based line indexes
my %src;      # file -> [lines]
for my $file (@sources) {
	my $lines = $src{$file} = slurp($file);
	for my $i (grep { $lines->[$_] =~ m{^//\s*mull-on\s*$} } 0 .. $#$lines) {
		my $sig = $i + 1;
		$sig++ while $sig < @$lines && $lines->[$sig] =~ /^@/;
		my ($name) = ($lines->[$sig] // '') =~ /^(\w+) :: proc\b/
			or die "$file:" . ($i + 1) . ": `// mull-on` must be followed by a top-level proc\n";
		my $open = $sig;
		$open++ until $open > $#$lines || $lines->[$open] =~ /\{\s*$/ && ($open == $sig || $lines->[$open] =~ /^\)/);
		my $close = $open + 1;
		$close++ until $close > $#$lines || $lines->[$close] =~ /^\}\s*$/;
		die "$file:" . ($sig + 1) . ": cannot find the body of $name (run odinfmt)\n" if $close > $#$lines;
		my $results = grep {/->/} @$lines[ $sig .. $open ];
		push @procs, { file => $file, name => $name, open => $open, close => $close, results => $results };
	}
}
die "mutate: no // mull-on markers under src/\n" unless @procs;

# 2. One-line mutants of the bodies, deduplicated.
my %mutants;    # id -> { proc, line (0-based), text }
my $next_id = 1;
for my $p (@procs) {
	my $dir = "$work/mutants/" . ($p->{file} =~ s{/}{_}gr) . "-$p->{name}";
	make_path($dir);
	spew("$dir/lines", map { $_ + 1 . "\n" } $p->{open} + 1 .. $p->{close} - 1);
	system("'$MUTATE' '$p->{file}' none '$rules' --noCheck --lines '$dir/lines' --mutantDir '$dir' >/dev/null 2>&1") == 0
		or die "mutate: universalmutator failed on $p->{file}\n";
	my $orig = $src{ $p->{file} };
	my ($last_return) = grep { $orig->[$_] =~ /\S/ } reverse $p->{open} + 1 .. $p->{close} - 1;
	$last_return = -1 unless $orig->[$last_return] =~ /^\s*return\b/;
	my %seen;
	for my $m (sort glob "$dir/*.mutant.*") {
		my $lines = slurp($m);
		next unless @$lines == @$orig;
		my @diff = grep { $lines->[$_] ne $orig->[$_] } 0 .. $#$orig;
		next unless @diff == 1 && $diff[0] > $p->{open} && $diff[0] < $p->{close};
		next if $seen{"$diff[0] $lines->[$diff[0]]"}++;
		# Deleting the final return would not compile in the original either.
		next if $p->{results} && $diff[0] == $last_return && $lines->[ $diff[0] ] =~ m{^\s*/\*};
		$mutants{ $next_id++ } = { proc => $p, line => $diff[0], text => $lines->[ $diff[0] ] };
	}
}
say STDERR 'mutate: ', scalar(keys %mutants), ' mutants in ', join(', ', map { $_->{name} } @procs);

# 3. Write the switched bodies; build; drop mutants the compiler rejects.
sub write_tree {
	my %where;    # "file line" (1-based, rewritten file) -> mutant id
	my %by_file;
	push @{ $by_file{ $_->{file} } }, $_ for @procs;
	for my $file (keys %by_file) {
		my $lines = $src{$file};
		my @out;
		my $at = 0;
		for my $p (sort { $a->{open} <=> $b->{open} } @{ $by_file{$file} }) {
			push @out, @$lines[ $at .. $p->{open} ];
			my @body = @$lines[ $p->{open} + 1 .. $p->{close} - 1 ];
			my $prev;
			for my $id (sort { $a <=> $b } grep { $mutants{$_}{proc} == $p } keys %mutants) {
				push @out, ($prev ? '} else ' : '') . "if __mut == $id {\n";
				# A mutant that unbalances the braces is reported at the next branch.
				$where{ "$file " . scalar @out } = $prev if $prev;
				$prev = $id;
				my $m = $mutants{$id};
				for my $i (0 .. $#body) {
					my $text = $p->{open} + 1 + $i == $m->{line} ? $m->{text} : $body[$i];
					push @out, $text;
					$where{ "$file " . scalar @out } = $id;
				}
			}
			if ($prev) {
				push @out, "} else {\n";
				$where{ "$file " . scalar @out } = $prev;
			}
			push @out, @body;
			push @out, "}\n" if $prev;
			$at = $p->{close};
		}
		push @out, @$lines[ $at .. $#$lines ];
		spew($file, @out);
		my ($pkg) = map { /^package (\w+)/ ? $1 : () } @$lines;
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
	my %bad;
	while ($out =~ m{^(\S+?):(\d+):\d+:\s*(?:Syntax\s+)?Error}mg) {
		my ($path, $line) = ($1, $2);
		my $file = $path =~ s{^\Q$tree\E/}{}r;
		my $id = $where->{"$file $line"};
		die "$out\nmutate: build error outside any mutant ($file:$line)\n" unless $id;
		$bad{$id} = 1;
	}
	die "$out\nmutate: build failed\n" unless %bad;
	print STDERR $out if $ENV{MUTATE_DEBUG};
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

# 5. Report against worktree paths.
sub show ($status, $id) {
	my $m    = $mutants{$id};
	my $orig = $src{ $m->{proc}{file} }[ $m->{line} ] =~ s/^\s+|\s+$//gr;
	my $new  = $m->{text} =~ s/^\s+|\s+$//gr;
	say "$m->{proc}{file}:", $m->{line} + 1, ": $status: $orig  =>  $new";
}
my $by_line = sub { $mutants{$a}{proc}{file} cmp $mutants{$b}{proc}{file} || $mutants{$a}{line} <=> $mutants{$b}{line} || $a <=> $b };
show('killed', $_) for $verbose ? sort $by_line @killed : ();
show('SURVIVED', $_) for sort $by_line @survived;
my $total = @killed + @survived;
printf "mutate: %d/%d killed (%.0f%%)\n", scalar @killed, $total, 100 * @killed / $total;
exit(@survived ? 1 : 0);
