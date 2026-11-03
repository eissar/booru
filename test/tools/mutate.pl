#!/usr/bin/env perl
# Mutation-test the `// mull-on` decls of one Odin test package with mull.
#
#     test/tools/mutate.pl src/cli [-- extra mull-runner args]
#
# Odin has no clang driver, so mull's IR plugin is applied by hand:
#
#   1. copy the tracked tree to a scratch dir and run mutate_annotate.odin on it,
#      which adds the mull-off comments that close each `// mull-on` region;
#   2. `odin build -build-mode:test -show-system-calls` to learn the link line,
#      then `odin test -build-mode:llvm-ir` to get one .ll per module;
#   3. compile every .ll with clang -fpass-plugin=mull-ir-frontend;
#   4. link with the captured flags and hand the binary to mull-runner.
#
# The worktree is never written. Tools default to the /tmp install described
# in test/tools/MUTATION.md; override with MULL_PLUGIN / MULL_RUNNER.
use v5.36;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Text::ParseWords qw(shellwords);

my $ROOT   = abs_path(dirname(__FILE__) . '/../..');
my $PLUGIN = $ENV{MULL_PLUGIN} // '/tmp/mull-pkg/usr/lib/mull-ir-frontend-21';
my $RUNNER = $ENV{MULL_RUNNER} // '/tmp/mull-deb13/usr/bin/mull-runner';
my @ODIN_FLAGS = ('-debug');

# Run a command (no shell); die on failure. Returns stdout when asked.
sub run ($opts, @cmd) {
	my $pid = open(my $out, '-|') // die "mutate: fork: $!\n";
	if (!$pid) {
		chdir $opts->{cwd} or die "mutate: chdir $opts->{cwd}: $!\n" if $opts->{cwd};
		open STDERR, '>&', \*STDOUT if $opts->{merge};
		open STDIN, '<', $opts->{stdin} or die "mutate: $opts->{stdin}: $!\n" if $opts->{stdin};
		exec @cmd or die "mutate: exec $cmd[0]: $!\n";
	}
	local $/;
	my $text = <$out> // '';
	close $out;
	die "mutate: `@cmd[0..1]` failed (exit " . ($? >> 8) . ")\n$text" if $? && !$opts->{nocheck};
	return wantarray ? ($text, $? >> 8) : $text;
}

sub odin_files ($dir) {
	opendir my $dh, $dir or die "mutate: $dir: $!\n";
	my @found;
	for my $e (sort grep { !/^\.\.?$/ } readdir $dh) {
		my $p = "$dir/$e";
		if    (-d $p)         { push @found, odin_files($p) }
		elsif ($e =~ /\.odin$/) { push @found, $p }
	}
	return @found;
}

my @args = @ARGV;
my @runner_args;
if (my ($i) = grep { $args[$_] eq '--' } 0 .. $#args) {
	@runner_args = @args[$i + 1 .. $#args];
	@args        = @args[0 .. $i - 1];
}
die "usage: test/tools/mutate.pl <package-dir> [-- mull-runner args]\n" unless @args == 1;
(my $pkg = $args[0]) =~ s{/+$}{};
for my $tool ($PLUGIN, $RUNNER) {
	die "mutate: missing $tool; see test/tools/MUTATION.md\n" unless -e $tool;
}

my $work = tempdir('booru-mutate-XXXXXXXX', TMPDIR => 1);
my $tree = "$work/tree";
say STDERR "mutate: scratch dir $work";

# 1. Scratch copy (tracked + untracked-but-not-ignored files) and annotate.
my $list = "$work/files";
{
	open my $fh, '>', $list or die "mutate: $list: $!\n";
	print $fh scalar run({ cwd => $ROOT }, qw(git ls-files -co --exclude-standard -z));
}
run({ cwd => $ROOT, stdin => $list }, 'rsync', '-a', '--from0', '--files-from=-', '.', $tree);
my @annotated = split ' ', scalar run({}, 'odin', 'run', "$ROOT/test/tools/mutate_annotate.odin", '-file',
	"-out:$work/annotate", '--', odin_files("$tree/src"));
die "mutate: no // mull-on markers under src/\n" unless @annotated;
say STDERR 'mutate: annotated ', join ' ', map { s{^\Q$tree\E/}{}r } @annotated;

# 2a. Link line from a normal test build.
my $exe = "$work/test";
my $calls = run({ cwd => $tree, merge => 1 },
	'odin', 'build', $pkg, '-build-mode:test', @ODIN_FLAGS, '-show-system-calls', "-out:$exe");
my ($link) = grep { /^clang / && /-o "\Q$exe\E"/ } map { s/^\s+|\s+$//gr } split /\n/, $calls;
die "mutate: no link line in odin -show-system-calls output\n" unless $link;
my @words = shellwords($link);
shift @words;    # clang
my (@keep, $skip);
for my $a (@words) {
	if    ($skip)                          { $skip = 0 }
	elsif ($a eq '-o')                     { $skip = 1 }
	elsif ($a !~ m{/test-.*\.o$})           { push @keep, $a }    # odin's temp objects
}

# 2b. One .ll per module.
my $ir = "$work/ir";
mkdir $ir or die "mutate: $ir: $!\n";
run({ cwd => $tree }, 'odin', 'test', $pkg, @ODIN_FLAGS, '-build-mode:llvm-ir', "-out:$ir");

# 3. Instrument. includePaths keeps mull to the annotated files.
my $config = "$work/mull.yml";
{
	open my $fh, '>', $config or die "mutate: $config: $!\n";
	print $fh "junkDetectionDisabled: true\nincludePaths:\n";
	print $fh "  - '^\Q$_\E\$'\n" for @annotated;
}
$ENV{MULL_CONFIG} = $config;
my $obj = "$work/obj";
mkdir $obj or die "mutate: $obj: $!\n";

my @lls = sort glob "$ir/*.ll";
my @objs;
my $jobs = 0;
my $max  = do { chomp(my $n = `nproc 2>/dev/null`); $n || 4 };
for my $ll (@lls) {
	(my $o = $ll) =~ s{^\Q$ir\E/(.*)\.ll$}{$obj/$1.o};
	push @objs, $o;
	if ($jobs >= $max) { wait; die "mutate: clang failed\n" if $?; $jobs-- }
	my $pid = fork // die "mutate: fork: $!\n";
	if (!$pid) {
		open STDOUT, '>', '/dev/null';
		open STDERR, '>', '/dev/null';
		exec 'clang', '-c', '-O0', '-Wno-override-module', "-fpass-plugin=$PLUGIN", $ll, '-o', $o;
		exit 127;
	}
	$jobs++;
}
while ($jobs--) { wait; die "mutate: clang failed\n" if $? }

# 4. Link and run.
my $mull_exe = "$work/test.mull";
run({}, 'clang', @objs, '-o', $mull_exe, @keep);
my ($report, $status) = run({ cwd => $tree, merge => 1, nocheck => 1 },
	$RUNNER, '--include-not-covered', @runner_args, $mull_exe);
# Report against worktree paths, not the scratch copy.
$report =~ s{\Q$tree\E/}{}g;
$report =~ s{ // mull-off}{}g;
print $report;
exit $status;
