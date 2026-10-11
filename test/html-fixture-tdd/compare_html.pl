#!/usr/bin/env perl
use v5.36;
use HTML::Tidy5;

@ARGV == 2 or die "Usage: $0 EXPECTED_FILE ACTUAL_HTML\n";
my ($path, $actual) = @ARGV;

open my $file, '<', $path or die "$path: $!\n";
my $expected = do { local $/; <$file> };
close $file or die "$path: $!\n";

my $tidy = HTML::Tidy5->new({
    sort_attributes => 'alpha',
    wrap => 0,
    indent => 0,
    tidy_mark => 0,
    merge_divs => 0,
    merge_spans => 0,
});

$expected = $tidy->clean($expected);
$actual = $tidy->clean($actual);

exit 0 if $actual eq $expected;

print STDERR "HTML mismatch: $path\n",
    "--- expected (normalized)\n$expected\n",
    "+++ actual (normalized)\n$actual\n";
exit 1;
