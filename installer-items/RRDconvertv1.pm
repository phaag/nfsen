#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#     this list of conditions and the following disclaimer in the documentation
#     and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
#  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
#  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
#  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
#  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
#  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
#  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
#  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
#  POSSIBILITY OF SUCH DAMAGE.
#
#  $Author: peter $
#
#  $Id: RRDconvertv1.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

package RRDconvertv1;

use strict;
use warnings;
use Data::Dumper;
use RRDs;
use NfSenRRD;

##########################
#
# Main
#
##########################

my $rrdtool = '';

my %rrd_array;
my @timevec;
my @progress = ( '|', '/', '-', '\\' );

sub ConvertDBs {
	my $profilename = shift;

	my $index = 0;

	%rrd_array = ();
	@timevec   = ();

	my $j = 0;
	$| = 1;
	foreach my $rrd_db ( @NfSenRRD::RRD_DS ) {
		print "Convert DBs: ", $progress[$index & 0x3], "\r";
		$index++;

		open DB, "$NfConf::PROFILESTATDIR/$profilename/$rrd_db.xml" or die "Can't open rrd DB '${rrd_db}.xml': $!\n";

		# wait for <rrd> tag
		while (<DB>) {
			next unless $_ =~ /<rrd>/;
			last;
		}
	
		# parse all available <ds>
		my @DS;
		my $in_ds = 0;
		while (<DB>) {
			last if $_ =~ /<rra>/;	# last if we found the rra section
			if ( $in_ds ) {
				if ( $_ =~ /<name>\s*([^\s]+)\s*<\/name>/ ) {
					push @DS, $1;
					next;
				}
				next unless $_ =~ /<\/ds>/;	
				# </ds> found
				$in_ds = 0;
			} else {
				next unless $_ =~ /<ds>/;	
				# <ds> found
				$in_ds = 1;
			}
		}
#		foreach my $ds ( @DS ) {
#			print "$ds\n";
#		}
	
		my $in_database = 0;

		while (<DB>) {
			if ( $in_database ) {
				if ( $_ =~ /<\/database>/ ) {
					$in_database = 0;
					next;
				}
				# <!-- 2005-12-11 23:30:00 CET / 1134340200 -->
				my ($time, $row);
				($time) = $_ =~ /\/\s+(\d+)\s+-->/;
				next unless $time;

				# <row><v> 1.4246717527e+07 </v><v> 6.2968940970e+07 </v><v> 6.5416970767e+06 </v><v> 7.089098 1553e+07 </v></row>
				# <row><v> NaN </v><v> NaN </v><v> NaN </v><v> NaN </v></row>
				($row) = $_ =~ /<row>\s*(.+)\s*<\/row>/;
				next unless $row;
		
				# remove value tags
				$row =~ s/<v>|<\/v>/ /g;
				$row =~ s/^\s*//;
				$row =~ s/\s*$//;
		
				# split values
				my @values;
				@values = split /\s+/, $row;
		
				# collect time values during first loop
				# skip rows not containing a number
				my $all_NaN = 1;
				foreach my $val ( @values) {
					 $all_NaN = 0 if $val ne 'NaN'
				}
				next if $all_NaN;

				# rearrange values
				for(my $i=0; $i< scalar @values; $i++ ) {
					my $ds = $DS[$i];
					next if defined $rrd_array{$ds}{$time}[$j];

					if ( $j == 0 ) {
						push @timevec, $time;
					}

					if ( $values[$i] ne 'NaN' ) {
						$rrd_array{$ds}{$time}[$j] = sprintf("%.0f", 300 * $values[$i]); # rounded value
					}
				}
			} else {
				if ( $_ =~ /<database>/ ) {
					$in_database = 1;
					next;
				}
			}
		}
		close DB;
		$j++;
	}
	@timevec = sort {$a <=>  $b} @timevec;

	print "Convert DBs: done.\n";

} # End of ConvertDBs

sub CreateNewRRD {
	my $profilename = shift;

	my $index = 0;

    my ($login,$pass,$uid,$gid) = getpwnam($NfConf::WWWUSER);
    if ( !defined $login ) {
            die "NFSEN user '$NfConf::WWWUSER' not found on this system\n";
    }

    if ( defined $NfConf::WWWGROUP ) {
        $gid  = getgrnam($NfConf::WWWGROUP) || 
            die "NFSEN group '$NfConf::WWWGROUP' not found on this system\n";
    }

	my %profileinfo = NfProfile::ReadProfile($profilename);
	if ( $profileinfo{'status'} eq 'empty' ) {
		print "Error Reading profile '$profilename'. Abort conversion\n";
		return 0;
	}

	# sort entries in profileinfo
	my @ProfileSources = keys %{$profileinfo{'channel'}};

	my $start_time = $timevec[0];
	foreach my $source ( @ProfileSources ) {
		if ( !exists($rrd_array{$source}) ) {
			print "==> Configured source '$source' does not exist in RRD\n";
			print "Abort creating DBs\n";
			return 0;
		}
		NfSenRRD::SetupRRD("$NfConf::PROFILESTATDIR/$profilename", $source, $start_time - 300, 1);
		chown $uid, $gid, "$NfConf::PROFILESTATDIR/$profilename/$source.rrd";
	}

	$| = 1;
	my $num = 0;
	foreach my $ds ( @ProfileSources ) {
		my $lasttime = $timevec[0] - 1;

		for ( my $i=0; $i < scalar @timevec; $i++ ) {
			my $time   = $timevec[$i];
			next if ( $time <= $lasttime );

			if ( ( $num & 0xFF ) == 0 ) {
				print "Writing new DBs: ", $progress[$index & 0x3], "\r";
				$index++;
			}
			$num++;

			# timegap - need to feed rrd with intermediate values
			my $values = $rrd_array{$ds}{$time};

			if ( ($time - $lasttime) > 300 ) {
				my $t    = $lasttime + 300;
				my $_ds  = join(':',@NfSenRRD::RRD_DS);
				my $_val = join(':', @$values);
				while ( $t < $time ) {
					my $err = NfSenRRD::UpdateDB("$NfConf::PROFILESTATDIR/$profilename", $ds, $t, $_ds , $_val);
            				if ( $Log::ERROR ) {
                				print("ERROR Update RRD: $Log::ERROR\n");
            				}
					$t += 300;

					if ( ( $num & 0xFF ) == 0 ) {
						print "Writing new DBs: ", $progress[$index & 0x3], "\r";
						$index++;
					}
					$num++;

				}
			}
			my $err = NfSenRRD::UpdateDB("$NfConf::PROFILESTATDIR/$profilename", $ds, $time,
				join(':',@NfSenRRD::RRD_DS) , join(':', @$values));
			if ( $Log::ERROR ) {
				print("ERROR Update RRD: $Log::ERROR\n");
			}
			$lasttime = $time;
		}

	}
	print "Writing new DBs: done.\n";

	return 1;

} # End of CreateNewRRD

sub UpdateProfile {
	my $profilename = shift;
	my $rrdtool	= shift;

	# backport from snapshot
	my $index = 0;
	print "Update profile '$profilename' \n";

	foreach my $rrd_db ( @NfSenRRD::RRD_DS ) {
		print "Dump RRD: ", $progress[$index & 0x3], "\r";
		$index++;
		system("$rrdtool dump $NfConf::PROFILESTATDIR/$profilename/$rrd_db.rrd > $NfConf::PROFILESTATDIR/$profilename/$rrd_db.xml");
		my $exit_value  = $? >> 8;
		my $signal_num  = $? & 127;
		my $dumped_core = $? & 128;
		if ( $exit_value != 0 ) {
			print "\nrrdtool exec error: exit: $exit_value, signal: $signal_num, coredump: $dumped_core\n";
			return 0;
		}
	}
	print "Dump RRD: done\n";
	my $ret = 0;
	ConvertDBs($profilename);
	$ret = CreateNewRRD($profilename);

	foreach my $rrd_db ( @NfSenRRD::RRD_DS ) {
		unlink "$NfConf::PROFILESTATDIR/$profilename/$rrd_db.xml";
		unlink "$NfConf::PROFILESTATDIR/$profilename/$rrd_db.rrd" if $ret;
	}

	return $ret;

} # End of UpdateProfile

1;

