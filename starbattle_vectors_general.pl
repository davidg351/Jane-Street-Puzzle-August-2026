#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);

my $SIZE = 11;

my $stars         = 2;
my $outfile       = 'input_vectors.txt';
my $regionsfile   = '';
my $max_solutions = 0;
my $verbose       = 0;
my $help          = 0;

GetOptions(
    'stars|s=i'   => \$stars,
    'output|o=s'  => \$outfile,
    'regions|r=s' => \$regionsfile,
    'max|m=i'     => \$max_solutions,
    'verbose|v'   => \$verbose,
    'help|h'      => \$help,
) or die usage();

if ($help) {
    print usage();
    exit 0;
}

die "--stars must be at least 1\n" if $stars < 1;

my $max_non_touching_per_line = int(($SIZE + 1) / 2);
die "--stars=$stars is impossible on an ${SIZE}x${SIZE} grid with the no-touching rule; maximum is $max_non_touching_per_line\n"
    if $stars > $max_non_touching_per_line;

die "--max must be >= 0\n" if $max_solutions < 0;

my @region_of;
my %region_size;
my %region_stars;

if ($regionsfile ne '') {
    open my $rf, '<', $regionsfile
        or die "Cannot open region file '$regionsfile': $!\n";

    my @rows;
    while (my $line = <$rf>) {
        chomp $line;
        $line =~ s/#.*$//;
        next if $line =~ /^\s*$/;
        my @x = split /\s+/, $line;
        push @rows, \@x;
    }
    close $rf;

    die "Region file must contain exactly $SIZE non-empty rows\n"
        unless @rows == $SIZE;

    for my $r (0 .. $SIZE - 1) {
        die "Region row ".($r + 1)." must contain exactly $SIZE labels\n"
            unless @{$rows[$r]} == $SIZE;

        for my $c (0 .. $SIZE - 1) {
            my $reg = $rows[$r][$c];
            $region_of[$r][$c] = $reg;
            $region_size{$reg}++;
            $region_stars{$reg} = 0;
        }
    }

    for my $reg (keys %region_size) {
        die "Region '$reg' contains only $region_size{$reg} cells, fewer than the requested $stars stars\n"
            if $region_size{$reg} < $stars;
    }
}

my @row_patterns;
my @working_cols;

sub generate_row_patterns {
    my ($next_col, $needed) = @_;

    if ($needed == 0) {
        push @row_patterns, [@working_cols];
        return;
    }

    for (my $c = $next_col; $c < $SIZE; $c++) {
        my $cells_left = $SIZE - $c;
        my $minimum_span = 2 * $needed - 1;
        last if $cells_left < $minimum_span;

        push @working_cols, $c;
        generate_row_patterns($c + 2, $needed - 1);
        pop @working_cols;
    }
}

generate_row_patterns(0, $stars);
die "No legal row patterns exist for $stars stars\n" unless @row_patterns;

my @grid = map { [(0) x $SIZE] } 0 .. $SIZE - 1;
my @col_stars = (0) x $SIZE;
my $solutions = 0;

open my $out, '>', $outfile
    or die "Cannot create '$outfile': $!\n";

my $all_zero = '0' x ($SIZE * $SIZE);
my $all_one  = '1' x ($SIZE * $SIZE);
my $alt_01 = '';
my $alt_10 = '';

for my $i (0 .. ($SIZE * $SIZE) - 1) {
    $alt_01 .= ($i % 2 == 0) ? '0' : '1';
    $alt_10 .= ($i % 2 == 0) ? '1' : '0';
}

print $out "$all_zero\n";
print $out "$alt_01\n";

sub can_place_row {
    my ($r, $cols_ref) = @_;
    my @cols = @$cols_ref;

    for my $c (@cols) {
        return 0 if $col_stars[$c] >= $stars;
    }

    if ($r > 0) {
        for my $c (@cols) {
            for my $pc ($c - 1, $c, $c + 1) {
                next if $pc < 0 || $pc >= $SIZE;
                return 0 if $grid[$r - 1][$pc];
            }
        }
    }

    if ($regionsfile ne '') {
        my %added;
        for my $c (@cols) {
            my $reg = $region_of[$r][$c];
            $added{$reg}++;
        }
        for my $reg (keys %added) {
            return 0 if $region_stars{$reg} + $added{$reg} > $stars;
        }
    }

    return 1;
}

sub place_row {
    my ($r, $cols_ref) = @_;
    for my $c (@$cols_ref) {
        $grid[$r][$c] = 1;
        $col_stars[$c]++;
        $region_stars{$region_of[$r][$c]}++ if $regionsfile ne '';
    }
}

sub remove_row {
    my ($r, $cols_ref) = @_;
    for my $c (@$cols_ref) {
        $grid[$r][$c] = 0;
        $col_stars[$c]--;
        $region_stars{$region_of[$r][$c]}-- if $regionsfile ne '';
    }
}

sub columns_still_possible {
    my ($next_row) = @_;
    my $rows_left = $SIZE - $next_row;

    for my $c (0 .. $SIZE - 1) {
        return 0 if $col_stars[$c] > $stars;
        return 0 if $col_stars[$c] + $rows_left < $stars;
    }
    return 1;
}

sub regions_still_possible {
    my ($next_row) = @_;
    return 1 if $regionsfile eq '';

    my %remaining_cells;
    for my $r ($next_row .. $SIZE - 1) {
        for my $c (0 .. $SIZE - 1) {
            $remaining_cells{$region_of[$r][$c]}++;
        }
    }

    for my $reg (keys %region_size) {
        return 0 if $region_stars{$reg} > $stars;
        my $available = $remaining_cells{$reg} // 0;
        return 0 if $region_stars{$reg} + $available < $stars;
    }
    return 1;
}

sub emit_solution {
    my $vector = '';
    for my $r (0 .. $SIZE - 1) {
        for my $c (0 .. $SIZE - 1) {
            $vector .= $grid[$r][$c] ? '1' : '0';
        }
    }

    die "Internal error: vector length is not ".($SIZE * $SIZE)."\n"
        unless length($vector) == $SIZE * $SIZE;

    print $out "$vector\n";
    $solutions++;
    print STDERR "solution $solutions: $vector\n" if $verbose;
}

sub search {
    my ($r) = @_;

    return 1 if $max_solutions && $solutions >= $max_solutions;

    if ($r == $SIZE) {
        for my $c (0 .. $SIZE - 1) {
            return 0 unless $col_stars[$c] == $stars;
        }

        if ($regionsfile ne '') {
            for my $reg (keys %region_size) {
                return 0 unless $region_stars{$reg} == $stars;
            }
        }

        emit_solution();
        return ($max_solutions && $solutions >= $max_solutions) ? 1 : 0;
    }

    for my $pattern (@row_patterns) {
        next unless can_place_row($r, $pattern);

        place_row($r, $pattern);

        if (columns_still_possible($r + 1)
            && regions_still_possible($r + 1)) {

            my $stop = search($r + 1);
            remove_row($r, $pattern);
            return 1 if $stop;
            next;
        }

        remove_row($r, $pattern);
    }

    return 0;
}

print STDERR "Searching ${SIZE}x${SIZE} Star Battle with $stars star(s) per row/column"
           . ($regionsfile ne '' ? "/region" : "") . "...\n"
    if $verbose;

search(0);

print $out "$alt_10\n";
print $out "$all_one\n";
close $out;

print STDERR "Generated $solutions Star Battle solution(s)\n";
print STDERR "Wrote ".($solutions + 4)." total vectors to '$outfile'\n";

sub usage {
    return <<'USAGE';
Usage:
  perl starbattle_vectors_general.pl [options]

Options:
  --stars N, -s N
      Number of stars required in every row and column.
      If a region file is supplied, also require N stars in every region.
      Default: 2

  --output FILE, -o FILE
      Output ASCII vector file.
      Default: input_vectors.txt

  --regions FILE, -r FILE
      Optional 11x11 region map.

  --max N, -m N
      Stop after N generated Star Battle solutions.
      The four fixed boundary vectors are still written.
      0 means generate all solutions.
      Default: 0

  --verbose, -v
      Print progress/solutions to stderr.

  --help, -h
      Show this help.

Output order:
  1. 121 zeros
  2. 010101... for 121 bits
  3. all generated Star Battle solutions
  4. 101010... for 121 bits
  5. 121 ones
USAGE
}
