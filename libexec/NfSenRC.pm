#!%%PERL%%
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	 this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	 this list of conditions and the following disclaimer in the documentation
#	 and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#	 used to endorse or promote products derived from this software without
#	 specific prior written permission.
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
#  $Id: NfSenRC.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $

package NfSenRC;

use strict;
use warnings;
use NfSen;
use Log;

# public map for collector mappings - more may be added in future
our %CollectorMap = ( 
	'netflow'	=> 'nfcapd',
	'sflow'		=> 'sfcapd',
	'pcap'		=> 'nfpcapd',
);

sub StartCollector {
	my $port = shift;

	# sim mode
	if ( $port == 0 ) {
		print "[no collector]";
		return;
	}
	my @SourceList;
	my $type = undef;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $_port = $NfConf::sources{$source}{'port'};
		if ( $_port == $port ) {
			push @SourceList, $source;
			my $_type = exists $NfConf::sources{$source}{'type'} ? $NfConf::sources{$source}{'type'}: 'netflow';
			if ( defined $type ) {
				if ( $type ne $_type ) {
					print "Can not start different type '$type' and '$_type' on same port!\n";
					return;
				}
			} else {
				$type = $_type;
			}
		}
	}

	print "(";
	print join ' ', @SourceList;
	print ")";

	# prepare args with first source
	my $collector	= $CollectorMap{$type};
	
	my $uid			= $NfConf::USER;
	my $gid 		= $NfConf::WWWGROUP  ? "$NfConf::WWWGROUP"   : "";
	my $buffer_opts = $NfConf::BUFFLEN ? "-B $NfConf::BUFFLEN"   : "";
	my $subdirlayout = $NfConf::SUBDIRLAYOUT ? "-S $NfConf::SUBDIRLAYOUT" : "";
	my $pidfile	 	= "$NfConf::PIDDIR/p${port}.pid";
	my $extensions  = $NfConf::EXTENSIONS ? $NfConf::EXTENSIONS : "";

	my $pid = CollectorStatus($port);
	if ( $pid > 0 ) {
		print "\nError( Port: $port ): a collector with pid[$pid] is already running\n";
		return;
	}

	my $ziparg = $NfConf::ZIPcollected ? '-z' : '';
	my $common_args = "-w -D -p $port -u $uid -g $gid $buffer_opts $subdirlayout -P $pidfile $ziparg $extensions";
	my $src_args;
	my $optargs = '';
	if ( scalar @SourceList > 1 ) {
		# multiple sources per collector
		foreach my $ident ( @SourceList ) {
			my $IP = $NfConf::sources{$ident}{'IP'};
			if ( !defined $IP ) {
				print "\nError( Port: $port ): Missing flow source IP address for '$ident'\n";
				return;
			}
			$src_args .= "-n $ident,$IP,$NfConf::PROFILEDATADIR/live/$ident ";
			$optargs     = exists $NfConf::sources{$ident}{'optarg'} ? "$optargs $NfConf::sources{$ident}{'optarg'}" : '';
		}
	} else {
		# single source
		my $ident = shift @SourceList;
		my $profiledir	= "$NfConf::PROFILEDATADIR/live/$ident";
		$optargs     = exists $NfConf::sources{$ident}{'optarg'} ? $NfConf::sources{$ident}{'optarg'} : '';
		$src_args = "-I $ident -l $profiledir ";
	}

	my $args = "$common_args $src_args $optargs";
	# print "\nRun: $NfConf::PREFIX/$collector $args\n";

	system("$NfConf::PREFIX/$collector $args");
	my $exit_value  = $main::child_exit >> 8;
	my $signal_num  = $main::child_exit & 127;
	my $dumped_core = $main::child_exit & 128;
	if ( $exit_value != 0 ) {
		print "$collector exec error: exit: $exit_value, signal: $signal_num, coredump: $dumped_core\n";
	} else {
		my $dowait = 5;
		while ( $dowait && ! -f $pidfile ) {
			sleep 1;
			$dowait--;
		}
		if ( $dowait ) {
			$pid = CollectorStatus($port);
			print "[$pid]";
		} else {
			print ": collector did not start - see logfile"
		}
	}

} # End of StartCollector

sub StopCollector {
	my $port = shift;

	# sim mode
	if ( $port == 0 ) {
		print "[no collector]";
		return;
	}

	my @SourceList;
	foreach my $source ( sort keys %{$$NfSen::hints{'sources'}} ) {
		my $_port = $$NfSen::hints{'sources'}{$source};
		if ( $_port == $port ) {
			push @SourceList, $source;
		}
	}

	print "(";
	print join ' ', @SourceList;
	print ")";

	my $pid = CollectorStatus($port);
	if ( $pid == 0 ) {
		print "[no collector]";
		return;
	} 

	if ( $pid == - 1 ) {
		print "[collector died unexpectedly]";
		return;
	}

	print "[$pid]";
	kill 'TERM', $pid || warn "Can't signal nfcapd: $! ";
	my $timeout = 10;
	while ( $timeout && -f "$NfConf::PIDDIR/p${port}.pid") {
		print ".";
		sleep 1;
		$timeout--;
	}
	if ( -f "$NfConf::PIDDIR/p${port}.pid") {
		print " Process [$pid] does not want to terminate!\n";
	}

} # End of StopCollector

sub NfSen_start {

	if ( ! -d "$NfConf::PIDDIR" ) {
		print "PIDDIR '$NfConf::PIDDIR' not found! NfSen installation problem!\n";
		return;
	}

	# Check if NfSen is already running
	if ( -f "$NfConf::PIDDIR/nfsend.pid" ) {
		open PID, "$NfConf::PIDDIR/nfsend.pid" || 
			die "Can't read pid file '$NfConf::PIDDIR/nfsend.pid': $!\n";
		my $pid = <PID>;
		chomp $pid;
		close PID;
		if ( kill( 0, $pid) == 1  ) {
			print "NfSen is already running!\n";
			return;
		} else {
			print "Unclean shutdown - run stop sequence first to clean up!\n";
			NfSen_stop();
		}
	}

	# Delete all possible remains from old runs.
	NfSen::CleanOrphans();

	# Decide how many collectors to start. 
	# nfcapd 1.6.x can handle several sources at the same port
	my %AllCollectors;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		push @{$AllCollectors{$port}}, $source;
	}

	if ( !Nfsources::ValidateSources() ) {
		print "Fix errors for %source in your config file and retry!\n";
		return;
	}
	print "Starting nfcapd:";
	foreach my $port ( keys %AllCollectors ) {
		StartCollector($port);
		print " ";
		select(undef, undef, undef, 0.2);
	}
	print "\n";

	print "Starting nfsend";
	system "$NfConf::BINDIR/nfsend";
	my $exit_value  = $main::child_exit >> 8;
	my $signal_num  = $main::child_exit & 127;
	my $dumped_core = $main::child_exit & 128;
	if ( $exit_value != 0 ) {
		print ": exec error: exit: $exit_value, signal: $signal_num, coredump: $dumped_core\n";
	}
	print ".\n";

} # End of NfSen_start

sub NfSen_stop {

	# Check how many collectors to stop
	# nfcapd 1.6.x can handle several sources at the same port
	my %AllCollectors;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		push @{$AllCollectors{$port}}, $source;
	}

	print "Shutdown nfcapd: ";
	foreach my $port ( keys %AllCollectors ) {
		StopCollector($port);
		print ' ';
	}
	print ".\n";

	print "Shutdown nfsend:";
	if ( -f "$NfConf::PIDDIR/nfsend.pid" ) {
		open PID, "$NfConf::PIDDIR/nfsend.pid" || 
			die "Can't read pid file '$NfConf::PIDDIR/nfsend.pid': $!\n";
		my $pid = <PID>;
		chomp $pid;
		close PID;
		print "[$pid]";
		if ( kill( 0, $pid) == 0  ) {
			print "[No such process]";
			unlink "$NfConf::PIDDIR/nfsend.pid";
		} else {
			kill 'TERM', $pid || warn "Can't signal nfsend: $! ";
			my $timeout = $NfConf::CYCLETIME;
			while ( $timeout && -f "$NfConf::PIDDIR/nfsend.pid") {
				print ".";
				sleep 1;
				$timeout--;
			}
		}
		if ( -f "$NfConf::PIDDIR/nfsend.pid") {
			print " Process [$pid] does not want to terminate!\n";
		}
	} else {
		print "[no pid file found!]";
	}
	print "\n";

} # End of NfSen_stop

sub NfSen_status {

	print "NfSen version: $$NfSen::hints{'version'}\n";
	if ( $NfConf::SIMmode ) {
		print "NfSen status: Simulation mode\n";
	} else {
		print "NfSen status:\n";
	}

	# Check how many collectors to stop
	# nfcapd 1.6.x can handle several sources at the same port
	my %AllCollectors;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		push @{$AllCollectors{$port}}, $source;
	}

	foreach my $port ( keys %AllCollectors ) {
		my $identref = $AllCollectors{$port};
		my $pid = CollectorStatus($port);
		print "Collector for (";
		print join ' ', @$identref;
		print ") port $port";

		if ( $pid == -1  ) {
			print " died for unknown reason.";
		} elsif ( $pid == 0 ) {
			print " is not running.";
		} else {
			print " is running [$pid].";
		}
		print "\n";
	}

	print "nfsen daemon: ";
	if ( -f "$NfConf::PIDDIR/nfsend.pid" ) {
		open PID, "$NfConf::PIDDIR/nfsend.pid" || 
			die "Can't read pid file '$NfConf::PIDDIR/nfsend.pid': $!\n";
		my $pid = <PID>;
		chomp $pid;
		close PID;
		print " pid: [$pid] ";
		if ( kill( 0, $pid) == 0  ) {
			print "died for unknown reason.";
			unlink "$NfConf::PIDDIR/nfsend.pid";
		} else {
				print "is running.";
		}
	} else {
		print "is not running.";
	}
	print "\n";

} # End of NfSen_status

sub CollectorStatus {
	my $port = shift;

	my $pidfile = "$NfConf::PIDDIR/p${port}.pid";
	if ( -f "$pidfile" ) {
		open PID, "$pidfile" || 
			die "Can't read pid file '$pidfile': $!\n";
		my $pid = <PID>;
		chomp $pid;
		close PID;
		if ( kill( 0, $pid) == 0  ) {
			unlink "$pidfile";
			return -1;
		} else {
			return $pid;
		}
	} else {
		return 0;
	}

} # End of CollectorStatus

sub NfSen_reload {

	if ( -f "$NfConf::PIDDIR/nfsend.pid" ) {
		print "Restart nfsend:";
		open PID, "$NfConf::PIDDIR/nfsend.pid" || 
			die "Can't read pid file '$NfConf::PIDDIR/nfsend.pid': $!\n";
		my $pid = <PID>;
		chomp $pid;
		close PID;
		print "[$pid]\n";
		kill 'USR1', $pid || warn "Can't restart nfsend: $! ";
	} else {
		print STDERR "No pid file found for nfsend - please restart manually\n";
	}

} # End of NfSen_reload

1;
