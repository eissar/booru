#!/usr/bin/env perl
# Mutation-test the `// mull-on` decls against the test:all suite with mull.
#
#     test/tools/mutate.pl [extra mull-runner args]
#
# Odin has no clang driver, so mull's IR plugin is applied by hand:
#
#   1. copy the tracked tree to a scratch dir and run mutate_annotate.odin on it,
#      which adds the mull-off comments that close each `// mull-on` region;
#   2. build test/ the way `task test:all:build` does, once with
#      -show-system-calls to learn the link line, once as LLVM IR (one .ll
#      per module);
#   3. drop the debug location from IR operators whose source line has no
#      operator that lowers to them (mull skips instructions without one), then
#      compile every .ll with clang -fpass-plugin=mull-ir-frontend;
#   4. link with the captured flags and hand the binary to mull-runner.
#
# The worktree is never written. Tools default to the /tmp install described
# in test/tools/MUTATION.md; override with MULL_PLUGIN / MULL_RUNNER.
use v5.36;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Text::ParseWords qw(shellwords);

my $PLUGIN = $ENV{MULL_PLUGIN} // '/tmp/mull-pkg/usr/lib/mull-ir-frontend-21';
my $RUNNER = $ENV{MULL_RUNNER} // '/tmp/mull-deb13/usr/bin/mull-runner';

# Output of a command run without a shell; stderr passes through. On failure
# the output is shown, since it may hold the error.
sub capture (@cmd) {
	open my $fh, '-|', @cmd or die "mutate: $cmd[0]: $!\n";
	local $/;
	my $out = <$fh> // '';
	close $fh or die "$out\nmutate: " . label(@cmd) . " failed\n";
	return $out;
}

sub sys (@cmd) { system(@cmd) == 0 or die "mutate: " . label(@cmd) . " failed\n" }

# `sh -c SCRIPT NAME ...` is labelled by NAME.
sub label (@cmd) { ($cmd[0] eq "sh" ? $cmd[3] : $cmd[0]) =~ s/ .*//r }

my @runner_args = @ARGV;
my @TEST_ALL     = ('test/', '-build-mode:test', '-all-packages', '-debug');
-e or die "mutate: missing $_; see test/tools/MUTATION.md\n" for $PLUGIN, $RUNNER;

chdir abs_path(dirname(__FILE__) . '/../..') or die "mutate: chdir: $!\n";
my $work = tempdir('booru-mutate-XXXXXXXX', TMPDIR => 1);
my $tree = "$work/tree";
say STDERR "mutate: scratch dir $work";

# 1. Scratch copy (tracked + untracked-but-not-ignored files), then annotate.
sys("git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- . '$tree'");
my @odin = map {"$tree/$_"} split /\0/, capture(qw(git ls-files -co --exclude-standard -z src/*.odin));
my @annotated = split ' ', capture('odin', 'run', 'test/tools/mutate_annotate.odin', '-file',
	"-out:$work/annotate", '--', "$work/table", @odin);
die "mutate: no // mull-on markers under src/\n" unless @annotated;
say STDERR 'mutate: annotated ', join ' ', map { s{^\Q$tree\E/}{}r } @annotated;

chdir $tree or die "mutate: chdir: $!\n";

# 2. Link line from a normal test build, minus odin's own objects and -o;
#    then one .ll per module.
my $calls = capture('sh', '-c', 'exec "$@" 2>&1', 'odin',
	'odin', 'build', @TEST_ALL, '-show-system-calls', "-out:$work/test");
my ($link) = $calls =~ m{^\s*(clang .*-o "\Q$work\E/test".*)$}m
	or die "mutate: no link line in odin -show-system-calls output\n";
my (undef, @words) = shellwords($link);
my @link_flags;
while (defined(my $w = shift @words)) {
	if ($w eq '-o') { shift @words; next }
	push @link_flags, $w unless $w =~ m{/test-.*\.o$};
}
mkdir "$work/ir";
sys('odin', 'test', grep({ $_ ne '-build-mode:test' } @TEST_ALL), '-build-mode:llvm-ir', "-out:$work/ir");

# 3a. Odin's debug info does not point at operators, so mull would also
#     mutate code Odin generates (string decoding, bounds and bool checks).
#     Keep an operator's location only if its source line has an operator
#     that lowers to it (the table from step 1); without a location mull
#     leaves the instruction alone. This stands in for
#     mull's junk detection, which only parses C and C++.
my %CLASS = (
	icmp => 'cmp', fcmp => 'cmp',
	add  => 'add', fadd => 'add',
	sub  => 'sub', fsub => 'sub', fneg => 'sub',
	mul  => 'mul', fmul => 'mul',
	sdiv => 'div', udiv => 'div', fdiv => 'div',
	srem => 'rem', urem => 'rem', frem => 'rem',
	and  => 'and', or   => 'or',  xor  => 'xor',
	shl  => 'shl', lshr => 'shr', ashr => 'shr',
);
my %ops;    # "file line" -> { class => 1 }, for every line of a marked proc
open my $tbl, '<', "$work/table" or die "mutate: table: $!\n";
while (<$tbl>) {
	chomp;
	my ($file, $line, $classes) = split /\t/, $_, 3;
	$ops{"$file $line"} = { map { $_ => 1 } split /,/, $classes // '' };
}
close $tbl;
my %marked = map { $_ => 1 } @annotated;
my ($kept, $dropped) = (0, 0);
for my $ll (glob "$work/ir/*.ll") {
	open my $in, '<', $ll or die "mutate: $ll: $!\n";
	my @lines = <$in>;
	close $in;
	my (%file, %scope, %loc);
	for (@lines) {
		if (/^!(\d+) = !DIFile\(filename: "([^"]*)", directory: "([^"]*)"/) {
			$file{$1} = $2 =~ m{^/} ? $2 : "$3/$2";
		} elsif (/^!(\d+) = (?:distinct )?!DI(?:Subprogram|LexicalBlock|LexicalBlockFile)\(.*?\bfile: !(\d+)/) {
			$scope{$1} = $2;
		} elsif (/^!(\d+) = !DILocation\(line: (\d+), column: (\d+), scope: !(\d+)/) {
			$loc{$1} = [$2, $4];
		}
	}
	next unless grep { $marked{$_} } values %file;
	my $changed;
	for (@lines) {
		my ($op, $id) = /^\s+%\S+ = (\w+)\b.*, !dbg !(\d+)$/ or next;
		my $class = $CLASS{$op} or next;
		my ($line, $sc) = @{ $loc{$id} // next };
		my $f = $file{ $scope{$sc} // '' } // next;
		my $here = $ops{"$f $line"} or next;    # mull-off code: leave it
		if ($here->{$class}) { $kept++; next }
		s/, !dbg !\d+$//;
		$dropped++;
		$changed = 1;
	}
	next unless $changed;
	open my $out, '>', $ll or die "mutate: $ll: $!\n";
	print $out @lines;
	close $out;
}
say STDERR "mutate: kept $kept IR operators in marked code, dropped $dropped generated ones";

# 3b. Instrument every module; includePaths keeps mull to the annotated files.
open my $cfg, '>', "$work/mull.yml" or die "mutate: mull.yml: $!\n";
print $cfg "junkDetectionDisabled: true\nincludePaths:\n", map {"  - '^\Q$_\E\$'\n"} @annotated;
close $cfg;
$ENV{MULL_CONFIG} = "$work/mull.yml";
sys('sh', '-c', q{ls "$1"/*.ll | xargs -P "$(nproc)" -n1 sh -c \
	'clang -c -O0 -Wno-override-module -fpass-plugin="$0" "$1" -o "$1.o" >/dev/null 2>&1' "$2"},
	'clang', "$work/ir", $PLUGIN);

# 4. Link and run. Report against worktree paths, not the scratch copy.
sys('clang', glob("$work/ir/*.o"), '-o', "$work/test.mull", @link_flags);
open my $mull, '-|', 'sh', '-c', 'exec "$@" 2>&1', 'mull',
	$RUNNER, '--include-not-covered', @runner_args, "$work/test.mull"
	or die "mutate: $RUNNER: $!\n";
while (<$mull>) {
	s{\Q$tree\E/}{}g;
	s{ // mull-off}{}g;
	print;
}
close $mull;
exit $? >> 8;
