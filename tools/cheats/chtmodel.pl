#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
#
# A model of rtl/pce/cheat_loader.sv: same state machine, same field matching,
# same commit-and-roll-back, so its output is what the RTL should emit for a
# given .cht. Keep the two in step.
#
# It exists because reading the parser was not enough to find a real bug in it.
# Run against libretro's whole PC Engine database it emitted codes from 135 of
# 397 files, when the correct answer is none: not one file in that database has
# an enable=true, so a correct parser emits nothing from any of them. The 135
# were the decimal-form files, where the alphabetical key order puts _enable
# before _value and a rollback that has already happened cannot stop a code the
# value key is about to stage. Disabled cheats and all 70 rumble-only rows were
# being poked into work RAM.
#
#   tools/cheats/chtmodel.pl FILE...
#   tools/cheats/run-fixtures.sh                       # the checked-in cases
#   tools/cheats/run-fixtures.sh /path/to/cht-database # the whole corpus
#
# Byte-for-byte model of rtl/pce/cheat_loader.sv, to check what it emits.
use strict; use warnings;
my @KEY = ('code','address','value','enable','cheat_type','desc');
my ($S_SOL,$S_PRE,$S_IDX,$S_FLD,$S_EQ,$S_VAL,$S_SKIP)=(0..6);

sub run {
  my ($bytes) = @_;
  my ($state,$ppos,$fpos)=($S_SOL,0,0);
  my @ok=(1)x6; my $field='';
  my ($grp,$grp_cur,$grp_valid,$grp_base,$stage)=(0,0,0,0,0);
  my ($da,$dv,$das,$dvs)=(0,0,0,0); my $dead=0;
  my ($ha,$hv,$inval,$anyhex)=(0,0,0,0);
  my $total=0; my @tbl; my @titles; my $tc=0; my $inq=0; my $dcol=0; my $cur_title='';
  for my $c (split //, $bytes) {
    my $eol = ($c eq "\n" || $c eq "\r");
    my $sp  = ($c eq ' ' || $c eq "\t");
    my $dig = ($c =~ /[0-9]/);
    my $hex = ($c =~ /[0-9a-fA-F]/);
    my $nib = $dig ? ord($c)-48 : ($c ge 'a' ? ord($c)-87 : ord($c)-55);
    if ($state==$S_SOL) {
      if ($eol||$sp) {} elsif ($c eq 'c') { $ppos=1; $state=$S_PRE } else { $state=$S_SKIP }
    } elsif ($state==$S_PRE) {
      my @want=('','h','e','a','t');
      if ($ppos<4) { if ($c eq $want[$ppos]) { $ppos++ } else { $state=$S_SKIP } }
      else { if ($c eq 't') { $grp=0; $state=$S_IDX } else { $state=$S_SKIP } }
    } elsif ($state==$S_IDX) {
      if ($dig) { $grp = $grp*10 + $nib }
      elsif ($c eq '_') {
        $fpos=0; @ok=(1)x6; $state=$S_FLD;
        if (!$grp_valid || $grp != $grp_cur) {
          if ($grp_valid && $total > $grp_base) { $titles[$tc]=$cur_title; $tc++ }
          $grp_cur=$grp; $grp_valid=1; $grp_base=$total; $stage=$total;
          ($da,$dv,$das,$dvs)=(0,0,0,0); $dead=0; $cur_title='';
        }
      } else { $state=$S_SKIP }
    } elsif ($state==$S_FLD) {
      if ($c =~ /[a-z_]/) {
        for my $k (0..5) {
          my $n=$KEY[$k];
          if ($fpos >= length($n) || $c ne substr($n,$fpos,1)) { $ok[$k]=0 }
        }
        $fpos++;
        if ($fpos > 15) { $fpos = $fpos % 16 }   # 4-bit counter, as in RTL
      } elsif ($c eq '=' || $sp) {
        $field='';
        for my $k (0..5) { if ($ok[$k] && $fpos == length($KEY[$k])) { $field=$KEY[$k] } }
        ($ha,$hv,$inval,$anyhex)=(0,0,0,0);
        $state = ($c eq '=') ? $S_VAL : $S_EQ;
      } else { $state=$S_SKIP }
    } elsif ($state==$S_EQ) {
      if ($c eq '=') { $state=$S_VAL } elsif (!$sp) { $state=$S_SKIP }
    } elsif ($state==$S_VAL) {
      if ($eol) {
        $state=$S_SOL; $inq=0;
        if ($field eq 'value' && $das && $dvs && !$dead && $da < 8192 && $stage < 32) {
          $tbl[$stage] = [$da, $dv]; $stage++; $total=$stage;
        }
      } else {
        if ($field eq 'code') {
          if ($hex) { $anyhex=1; if ($inval) { $hv = (($hv<<4)|$nib) & 0xFF } else { $ha = (($ha<<4)|$nib) & 0xFFFFFF } }
          elsif ($c eq ':') { $inval=1 }
          elsif ($c eq '+' || $c eq '"') {
            if ($anyhex && $inval && (($ha>>13)&0x7FF)==0xF8 && $stage<32) {
              $tbl[$stage]=[$ha & 0x1FFF, $hv]; $stage++; $total=$stage;
            }
            ($ha,$hv,$inval,$anyhex)=(0,0,0,0);
          }
        } elsif ($field eq 'address') { if ($dig) { $da=$da*10+$nib; $das=1 } }
        elsif ($field eq 'value')   { if ($dig) { $dv=($dv*10+$nib)&0xFF; $dvs=1 } }
        elsif ($field eq 'enable')  { if ($c=~/^[tT]$/) {} elsif ($c=~/^[fF]$/) { $dead=1; $stage=$grp_base; $total=$grp_base } }
        elsif ($field eq 'cheat_type') { if ($c eq '0') { $dead=1; $stage=$grp_base; $total=$grp_base } }
        elsif ($field eq 'desc') {
          if ($c eq '"') { if ($inq) { $inq=0 } else { $inq=1; $dcol=0 } }
          elsif ($inq && $dcol<26) { $cur_title .= uc($c); $dcol++ }
        }
      }
    } elsif ($state==$S_SKIP) { if ($eol) { $state=$S_SOL } }
  }
  if ($grp_valid && $total > $grp_base) { $titles[$tc]=$cur_title; $tc++ }
  return ($total, \@tbl, $tc, \@titles);
}

for my $f (@ARGV) {
  open my $fh,'<',$f or die $!; local $/; my $b=<$fh>; close $fh;
  my ($n,$tbl,$tc,$titles)=run($b);
  my $base=$f; $base=~s{.*/}{};
  printf "%-45s codes=%d titles=%d\n", $base, $n, $tc;
  for my $i (0..$n-1) { printf "    [%2d] 1f%04x : %02x\n", $i, $tbl->[$i][0], $tbl->[$i][1] }
  for my $i (0..$tc-1) { printf "    title[%d] = %s\n", $i, $titles->[$i] // '' }
}
