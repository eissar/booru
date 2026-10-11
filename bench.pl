#!/usr/bin/env perl
use v5.36;
use JSON::PP qw(decode_json);

my $report = decode_json do { local $/; <> };
our ($metric, $baseline, $touched, $freed);

format STDOUT_TOP =
metric                baseline       touched         freed
.

format STDOUT =
@<<<<<<<<<<<<<<< ^#####.## MiB ^#####.## MiB ^#####.## MiB
$metric,         $baseline,    $touched,     $freed
.

for my $path (
    [cgroup  => 'memory.current'],
    [cgroup  => 'memory.peak'],
    [cgroup  => 'memory.stat', 'anon'],
    [cgroup  => 'memory.stat', 'file'],
    [cgroup  => 'memory.stat', 'kernel'],
    [cgroup  => 'memory.stat', 'sock'],
    [process => 'smaps_rollup', 'Rss'],
    [process => 'smaps_rollup', 'Pss'],
    [process => 'status', 'VmHWM'],
) {
    $metric = $path->[-1];
    ($baseline, $touched, $freed) = map {
        my $value = $report->{phases}{$_};
        $value = $value->{$_} for @$path;
        !defined $value    ? undef
      : $value =~ s/ kB$// ? $value / 1024
      :                      $value / 1024**2;
    } qw(baseline touched freed);
    write;
}
