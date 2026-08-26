#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);

my ($mode,$map_file,$top,$omit_power,$include_decap,$verbose) =
   ('skywater',undef,undef,0,0,0);

GetOptions(
  'mode=s'         => \$mode,
  'map=s'          => \$map_file,
  'top=s'          => \$top,
  'omit-power!'    => \$omit_power,
  'include-decap!' => \$include_decap,
  'verbose|v'      => \$verbose,
  'help|h'         => sub { print usage(); exit 0 },
) or die usage();

die "--mode must be skywater or gate\n" unless $mode eq 'skywater' || $mode eq 'gate';
die "--map is required for --mode=gate\n" if $mode eq 'gate' && !defined $map_file;
my $file = shift @ARGV // die usage();
die "Cannot open '$file'\n" unless -f $file;
die "Cannot open mapping '$map_file'\n" if defined($map_file) && !-f $map_file;

sub net_name {
  my ($n)=@_;
  $n =~ s/\[/_/g; $n =~ s/\]/_/g; $n =~ s/[^A-Za-z0-9_\$]/_/g;
  $n = "n_$n" if $n =~ /^\d/;
  return $n;
}
sub power_pin {
  my ($p)=@_;
  return $p =~ /^(VPWR|VGND|VNB|VPB)$/;
}

# Join CDL continuation lines.
open my $fh,'<',$file or die "$file: $!\n";
my @raw=<$fh>; close $fh;
my @lines;
for my $l (@raw) {
  chomp $l; next if $l =~ /^\s*\*/;
  if ($l =~ /^\s*\+/) {
    $l =~ s/^\s*\+//;
    $lines[-1] .= " $l" if @lines;
  } else { push @lines,$l; }
}

# Parse subcircuits and their formal pins.
my (%pins,@subs);
for my $l (@lines) {
  if ($l =~ /^\s*\.subckt\s+(\S+)\s*(.*)$/i) {
    my ($n,$r)=($1,$2 // '');
    my @p=grep {length} split /\s+/,$r;
    $pins{$n}=\@p; push @subs,$n;
  }
}
die "No .subckt definitions found\n" unless @subs;
$top //= $subs[-1];
die "Top-level subckt '$top' not found\n" unless exists $pins{$top};
my %known=map {$_=>1} @subs;

# Mapping records:
# DIRECT <source_cell> <output_cell>
#   PIN <source_pin> <output_pin>
#   END
#
# COMPOSITE <source_cell>
#   STAGE <stage_name> <cell_type>
#     CONNECT <stage_pin> <source_pin|stage.stage_pin>
#     OUT <stage_pin>
#     ENDSTAGE
#   OUTPUT <source_pin> <stage.stage_pin>
#   END
#
# STAGE blocks may form an arbitrary directed network. A reference to
# "stage.pin" must refer to an earlier stage. Source-cell pins are referenced
# by their original names. OUTPUT connects the source cell's output pin to
# the selected stage output. Each OUT pin gets a generated intermediate net.
my (%direct,%composite,%skip,%unsupported);

if (defined $map_file) {
  open my $mf,'<',$map_file or die "$map_file: $!\n";
  my ($kind,$cur,$stage);

  while (my $l=<$mf>) {
    chomp $l; $l =~ s/^\s+|\s+$//g;
    next if !$l || $l =~ /^#/;
    my @f=split /\s+/,$l; my $d=shift @f;

    if ($d eq 'DIRECT') {
      die "Bad DIRECT: $l\n" unless @f==2;
      my ($src,$dst)=@f;
      die "Unknown cell '$src' in mapping\n" unless exists $pins{$src};
      $direct{$src}={name=>$dst,pins=>{}};
      delete $composite{$src};
      ($kind,$cur,$stage)=('DIRECT',$src,undef);
    } elsif ($d eq 'COMPOSITE') {
      die "Bad COMPOSITE: $l\n" unless @f==1;
      my $src=$f[0];
      die "Unknown cell '$src' in mapping\n" unless exists $pins{$src};
      $composite{$src}={stages=>{},order=>[],output=>undef};
      delete $direct{$src};
      ($kind,$cur,$stage)=('COMPOSITE',$src,undef);
    } elsif ($d eq 'PIN') {
      die "PIN only valid in DIRECT: $l\n" unless $kind eq 'DIRECT' && $cur;
      die "Bad PIN: $l\n" unless @f==2;
      $direct{$cur}{pins}{$f[0]}=$f[1];
    } elsif ($d eq 'STAGE') {
      die "STAGE only valid in COMPOSITE: $l\n" unless $kind eq 'COMPOSITE' && $cur;
      die "Bad STAGE: $l\n" unless @f==2;
      my ($sn,$ct)=@f;
      die "Duplicate stage '$sn' in '$cur'\n" if exists $composite{$cur}{stages}{$sn};
      $composite{$cur}{stages}{$sn}={cell=>$ct,conns=>{},outs=>{}};
      push @{$composite{$cur}{order}},$sn;
      $stage=$sn;
    } elsif ($d eq 'CONNECT') {
      die "CONNECT only valid in STAGE: $l\n" unless $stage;
      die "Bad CONNECT: $l\n" unless @f==2;
      $composite{$cur}{stages}{$stage}{conns}{$f[0]}=$f[1];
    } elsif ($d eq 'OUT') {
      die "OUT only valid in STAGE: $l\n" unless $stage;
      die "Bad OUT: $l\n" unless @f==1;
      $composite{$cur}{stages}{$stage}{outs}{$f[0]}=1;
    } elsif ($d eq 'ENDSTAGE') {
      die "ENDSTAGE without STAGE\n" unless $stage;
      $stage=undef;
    } elsif ($d eq 'OUTPUT') {
      die "OUTPUT only valid in COMPOSITE: $l\n" unless $kind eq 'COMPOSITE' && $cur && !$stage;
      die "Bad OUTPUT: $l\n" unless @f==2 && $f[1]=~/^([^.]+)\.(.+)$/;
      $composite{$cur}{output}=[$f[0],$1,$2];
    } elsif ($d eq 'END') {
      die "Unclosed STAGE in '$cur'\n" if $stage;
      $cur=undef; $kind=undef;
    } elsif ($d eq 'SKIP') {
      die "Bad SKIP: $l\n" unless @f==1;
      $skip{$f[0]}=1;
    } elsif ($d eq 'UNSUPPORTED') {
      die "Bad UNSUPPORTED: $l\n" unless @f==1;
      $unsupported{$f[0]}=1;
    } else {
      die "Unknown mapping directive '$d'\n";
    }
  }
  close $mf;
}

# Find top-level X instances by locating the cell token among known subckts.
my @inst;
my $inside=0;
for my $l (@lines) {
  if ($l =~ /^\s*\.subckt\s+(\S+)/i) { $inside=($1 eq $top); next; }
  if ($l =~ /^\s*\.ends\b/i) { $inside=0; next; }
  next unless $inside && $l =~ /^\s*[Xx]\S+/;
  my @t=split /\s+/,$l; my $iname=shift @t;
  my ($cell,$ci);
  for my $i(0..$#t) { if ($known{$t[$i]}) {($cell,$ci)=($t[$i],$i);last;} }
  die "Cannot identify cell for instance $iname\n" unless defined $cell;
  my @c=@t[0..$ci-1];
  my $np=@{$pins{$cell}};
  die "$iname ($cell): expected $np connections, found ".scalar(@c)."\n"
      unless @c==$np;
  push @inst,[$iname,$cell,\@c];
}

# Check mappings and build internal net list.
my @ports=map {net_name($_)} @{$pins{$top}};
my %topport=map {$_=>1}@ports;
my %nets;
my $emitted=0;

sub mapping_kind {
  my ($cell)=@_;
  return 'skip' if $skip{$cell};
  return 'direct' if $direct{$cell};
  return 'composite' if $composite{$cell};
  return 'unsupported' if $unsupported{$cell};
  return 'none';
}

for my $r(@inst) {
  my ($iname,$cell,$c)=@$r;
  next if !$include_decap && $cell =~ /(?:^|__)decap_\d+$/;
  my $k=$mode eq 'skywater' ? 'skywater' : mapping_kind($cell);
  die "No mapping for $cell (instance $iname)\n" if $mode eq 'gate' && $k eq 'none';
  die "Mapping marks $cell UNSUPPORTED (instance $iname)\n" if $mode eq 'gate' && $k eq 'unsupported';
  next if $k eq 'skip';
  my @fp=@{$pins{$cell}};
  for my $i(0..$#fp) {
    my $p=$fp[$i]; next if ($mode eq 'gate' && $k eq 'direct' && !exists $direct{$cell}{pins}{$p});
    next if ($mode eq 'gate' && $k eq 'composite' && !exists $composite{$cell}{pins}{$p});
    next if ($mode eq 'gate' || $omit_power) && power_pin($p);
    my $n=net_name($c->[$i]); $nets{$n}=1 unless $topport{$n};
  }
  # Composite stage wires. Every declared OUT pin is a generated net,
  # except the final OUTPUT connection which is tied directly to the
  # source-cell output net.
  if ($mode eq 'gate' && $k eq 'composite') {
    my $m=$composite{$cell};
    my $final_stage = $m->{output}[1];
    my $final_pin   = $m->{output}[2];
    for my $sn (@{$m->{order}}) {
      for my $op (keys %{$m->{stages}{$sn}{outs}}) {
        next if defined($final_stage) && $sn eq $final_stage && $op eq $final_pin;
        $nets{"__${iname}_${sn}_${op}"}=1;
      }
    }
  }
}

print "/* Generated from $file */\n";
print "/* mode=$mode", defined($map_file) ? ", map=$map_file" : "", " */\n\n";
print "module ".net_name($top)." (\n";
for my $i(0..$#ports) { print "    $ports[$i]".($i==$#ports?"\n":",\n"); }
print ");\n\n";
print "    wire ".join(", ",sort keys %nets).";\n\n" if %nets;

for my $r(@inst) {
  my ($iname,$cell,$c)=@$r;
  next if !$include_decap && $cell =~ /(?:^|__)decap_\d+$/;
  if ($mode eq 'skywater') {
    print "    $cell $iname (\n";
    my @p;
    for my $i(0..$#{$pins{$cell}}) {
      my $fp=$pins{$cell}[$i]; next if $omit_power && power_pin($fp);
      push @p,"        .$fp(".net_name($c->[$i]).")";
    }
    print join(",\n",@p),"\n    );\n\n";
    next;
  }
  my $k=mapping_kind($cell);
  next if $k eq 'skip';
  die "No usable mapping for $cell\n" unless $k eq 'direct' || $k eq 'composite';

  if ($k eq 'direct') {
    print "    $direct{$cell}{name} $iname (\n";
    my @p;
    for my $i(0..$#{$pins{$cell}}) {
      my $fp=$pins{$cell}[$i]; next if power_pin($fp) || !exists $direct{$cell}{pins}{$fp};
      push @p,"        .".$direct{$cell}{pins}{$fp}."(".net_name($c->[$i]).")";
    }
    print join(",\n",@p),"\n    );\n\n";
  } else {
    my $m=$composite{$cell};
    die "Composite mapping for $cell has no OUTPUT\n" unless $m->{output};

    my %formal = map { $_ => 1 } @{$pins{$cell}};
    my %stage_out_net;

    my ($source_out,$final_stage,$final_pin)=@{$m->{output}};
    die "Composite mapping for $cell references unknown source output '$source_out'\n"
      unless $formal{$source_out};

    for my $sn (@{$m->{order}}) {
      my $st=$m->{stages}{$sn};
      my $stage_inst="${iname}__${sn}";
      my %conn;

      for my $sp (keys %{$st->{conns}}) {
        my $ref=$st->{conns}{$sp};
        my $net;

        if ($formal{$ref}) {
          # Source-cell input.
          my $idx=index_of_pin($pins{$cell},$cell,$ref,undef);
          $net=net_name($c->[$idx]);
        } elsif ($ref =~ /^([^.]+)\.(.+)$/) {
          my ($ps,$pp)=($1,$2);
          die "Composite $cell/$iname: stage '$ps' must precede '$sn'\n"
            unless exists $stage_out_net{$ps}{$pp};
          $net=$stage_out_net{$ps}{$pp};
        } else {
          die "Composite $cell/$iname: unknown CONNECT reference '$ref'\n";
        }
        $conn{$sp}=$net;
      }

      for my $op (keys %{$st->{outs}}) {
        my $net;
        if ($sn eq $final_stage && $op eq $final_pin) {
          my $idx=index_of_pin($pins{$cell},$cell,$source_out,undef);
          $net=net_name($c->[$idx]);
        } else {
          $net="__${iname}_${sn}_${op}";
        }
        $stage_out_net{$sn}{$op}=$net;
        $conn{$op}=$net unless exists $conn{$op};
      }

      die "Composite $cell/$iname: no OUT pin declared for stage '$sn'\n"
        unless keys %{$st->{outs}};

      print "    $st->{cell} $stage_inst (\n";
      my @p;
      for my $sp (sort keys %conn) {
        push @p,"        .$sp($conn{$sp})";
      }
      print join(",\n",@p),"\n    );\n";
    }
    print "\n";
  }
}

print "endmodule\n";

sub index_of_pin {
  my ($a,$cell,$p1,$p2)=@_;
  for my $i(0..$#$a) {
    return $i if defined($p1) && $a->[$i] eq $p1;
    return $i if defined($p2) && $a->[$i] eq $p2;
  }
  die "Cannot find pin in $cell\n";
}

sub usage {
return <<'EOT';
Usage:
  perl spice2verilog_9t_composite.pl --mode=gate --map=skywater_to_9t_composite.map input.spi > output.v

Options:
  --mode=skywater
  --mode=gate --map=FILE
  --omit-power
  --include-decap
  --top=NAME
  --verbose
  --help

Mapping format:

  DIRECT <source_cell> <output_cell>
    PIN <source_pin> <output_pin>
    END

  COMPOSITE <source_cell>
    STAGE <name> <9t_cell>
      CONNECT <stage_pin> <source_pin>
      CONNECT <stage_pin> <previous_stage>.<output_pin>
      OUT <stage_output_pin>
      ENDSTAGE
    STAGE ...
    OUTPUT <source_output_pin> <stage>.<stage_output_pin>
    END

  SKIP <source_cell>
  UNSUPPORTED <source_cell>

Composite stages are emitted in the order in which they occur in the
mapping file. A stage may reference outputs from earlier stages, allowing
arbitrary multi-stage Boolean decompositions.
EOT
}
