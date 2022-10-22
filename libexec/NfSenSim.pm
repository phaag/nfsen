#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	  this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	  this list of conditions and the following disclaimer in the documentation
#	  and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#	  used to endorse or promote products derived from this software without
#	  specific prior written permission.
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
#  $Id: NfSenSim.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $


package NfSenSim;

use NfConf;
use NfProfile;
use NfSenRC;
use NfSenRRD;
use NfAlert;

sub ResetNfSen {

	my $tstart = NfSen::ISO2UNIX($NfConf::sim{'tstart'});
	
	print "Reset NfSen:\n";
	if ( -f "$NfConf::PIDDIR/nfsend.pid" ) {
		print "Stop NfSen while reseting ...\n";
		NfSenRC::NfSen_stop();
	}

	if ( !NfSen::DropPriv($NfConf::USER) ) {
		die "$Log::ERROR\n";
	}

	my @AllProfileGroups = NfProfile::ProfileGroups();
	foreach my $profilegroup ( @AllProfileGroups ) {
		my @AllProfiles = NfProfile::ProfileList($profilegroup);
		foreach my $profilename ( @AllProfiles ) {
			next if $profilename eq 'live' && $profilegroup eq '.';
	
			print "Clear profile '$profilename' in group '$profilegroup'\n";

			my @dirs;
			push @dirs, "$NfConf::PROFILESTATDIR";
			if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
				push @dirs, "$NfConf::PROFILEDATADIR";
			}

			foreach my $dir ( @dirs ) {
				my $command = "/bin/rm -rf $dir/$profilegroup/$profilename";
				system($command);
			}
		}
	}

	foreach my $alertname ( NfAlert::AlertList() ) {

		print "Clear alert '$alertname'\n";

		my @dirs;
		push @dirs, "$NfConf::PROFILESTATDIR";
		if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
			push @dirs, "$NfConf::PROFILEDATADIR";
		}

		foreach my $dir ( @dirs ) {
			my $command = "/bin/rm -rf $dir/~$alertname";
			system($command);
		}
	}
	
	print "Remove filters ...";
	my $command = "/bin/rm -rf $NfConf::FILTERDIR/*";
	system($command);
	print "done.\n";

	print "Reset profile 'live'\n";
	my %profileinfo = NfProfile::ReadProfile('live', '.');
	$profileinfo{'tcreate'} 	= $tstart;
	$profileinfo{'tbegin'}		= $tstart;
	$profileinfo{'tstart'} 		= $tstart;
	$profileinfo{'tend'} 		= $tstart;
	$profileinfo{'updated'}		= $tstart - $NfConf::CYCLETIME;
	$profileinfo{'expire'} 		= 0;
	$profileinfo{'maxsize'} 	= 0;
	$profileinfo{'size'} 		= 0;
	$profileinfo{'filter'}		= "";
	$profileinfo{'type'} 		= 0;
	$profileinfo{'locked'} 		= 0;
	$profileinfo{'status'} 		= 'OK';

	foreach my $db ( keys %NfConf::sources ) {
		NfSenRRD::SetupRRD("$NfConf::PROFILESTATDIR/live", $db, $tstart - $NfConf::CYCLETIME, 1);
	}
	if ( $Log::ERROR ) {
		die "Error setup RRD DBs: $Log::ERROR\n";
	}

	if ( exists $NfConf::sim{'tbegin'} ) {
		print "Preset profile 'live'\n";
		my $tbegin = NfSen::ISO2UNIX($NfConf::sim{'tbegin'});
		foreach my $channel ( NfProfile::ProfileChannels(\%profileinfo) ) {
			for ( my $t = $tstart; $t <= $tbegin; $t += $NfConf::CYCLETIME ) {
				my $t_iso 	= NfSen::UNIX2ISO($t);
				my $subdirs = NfSen::SubdirHierarchy($t);
				my ($statinfo, $exit_code, $err ) = NfProfile::ReadStatInfo(\%profileinfo, $channel, $subdirs, $t_iso, undef);
				if ( $exit_code != 0 ) {
					warn "$t_iso: $err";
					next;
				}
	
				my @_values = ();
				foreach my $ds ( @NfSenRRD::RRD_DS ) {
       				if ( !defined $$statinfo{$ds} || $$statinfo{$ds} == - 1 ) {
           				push @_values, 0;
       				} else {
           				push @_values, $$statinfo{$ds};
       				}
				}
				$err = NfSenRRD::UpdateDB("$NfConf::PROFILESTATDIR/live", $channel, $t,
				join(':',@NfSenRRD::RRD_DS) , join(':', @_values));
				if ( $Log::ERROR ) {
					die "ERROR Update RRD time: '$t_iso', db: '$channel', profile: '$profilename' group '$profilegroup' : $Log::ERROR";
				}
			}
		}
		$profileinfo{'tend'}	= $tbegin;
		$profileinfo{'updated'}	= $tbegin - $NfConf::CYCLETIME;
		NfSenRRD::UpdateGraphs('live', '.', $tbegin - $NfConf::CYCLETIME, 1);
	} else {
		NfSenRRD::UpdateGraphs('live', '.', $tstart - $NfConf::CYCLETIME, 1);
	}

	NfProfile::WriteProfile(\%profileinfo);
	delete $$NfSen::hints{'sim'};
	NfSen::StoreHints();
	print "Reset NfSen completed.\n";

} # End of ResetNfSen

sub NewSlots {
	my $timeslot = shift;

	my $t_iso = NfSen::UNIX2ISO($timeslot);
	my %profileinfo = NfProfile::ReadProfile('live', '.');

	my $failed = 0;
	foreach my $channel ( NfProfile::ProfileChannels(\%profileinfo) ) {
		my $subdirs = NfSen::SubdirHierarchy($timeslot);
		my ($statinfo, $exit_code, $err ) = NfProfile::ReadStatInfo(\%profileinfo, $channel, $subdirs, $t_iso, undef);
		if ( $exit_code != 0 ) {
			$failed = 1;
			next;
		}
	}
	return $failed ? 0 : 1;

} # End of NewSlots
1;
