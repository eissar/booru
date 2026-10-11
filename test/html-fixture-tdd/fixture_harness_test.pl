#!/usr/bin/env perl
use v5.36;
use FindBin;
use HTML::Tidy5;
use Test::More;

chdir "$FindBin::Bin/../.." or die "Repository root: $!\n";
my $filter = shift // '';
my $fixtures = 'test/html-fixture-tdd/fixture';

open my $harness, '-|', 'odin', 'run',
    'test/html-fixture-tdd/fixture_harness.odin',
    '-file', '--', $fixtures
    or die "Cannot start Odin harness: $!\n";
my $output = do { local $/; <$harness> };
close $harness or die "Odin harness failed (status $?)\n";
my %cases = $output =~ /<<<CASE (.+?)>>>\n([\s\S]*?)\n<<<END>>>/g;

my $tidy = HTML::Tidy5->new({
    sort_attributes => 'alpha',
    wrap => 0,
    indent => 0,
    tidy_mark => 0,
    merge_divs => 0,
    merge_spans => 0,
});

for my $name (
    'toast',
    'item_card',
    'photo_grid',
    'inspector',
    'gallery_content',
    'gallery_page',
) {
    next if index($name, $filter) < 0;
    unless (exists $cases{$name}) {
        fail("template: $name (missing harness case)");
        next;
    }

    open my $file, '<', "$fixtures/$name.expected.html"
        or die "$fixtures/$name.expected.html: $!\n";
    my $expected = do { local $/; <$file> };
    close $file;

    is($tidy->clean($cases{$name}), $tidy->clean($expected), "template: $name");
}

done_testing;
