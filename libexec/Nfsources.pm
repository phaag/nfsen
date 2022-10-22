#!%%PERL%%
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
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
#  $Id: Nfsources.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $

package Nfsources;

use strict;
use warnings;
use Log;

use NfSenRC;

sub ValidateSources {

	# Bundle the sources in the number of collectors since
	# nfcapd 1.6.x can handle several sources at the same port
	my %AllCollectors;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		push @{$AllCollectors{$port}}, $source;
	}

	foreach my $port ( keys %AllCollectors ) {
		# no collector
		if ( $port == 0 ) {
			next;
		}

		my $identref 	= $AllCollectors{$port};
		my $ident 		= $$identref[0];
		my $type		= exists $NfConf::sources{$ident}{'type'} ? $NfConf::sources{$ident}{'type'}: 'netflow';
		my $collector 	= $NfSenRC::CollectorMap{$type};

		if ( !defined $NfSenRC::CollectorMap{$type} ) {
			print "Source '$ident': unknown collector for type '$type'";
			return 0;
		} elsif ( ! -f "$NfConf::PREFIX/$collector" ) {
			print "Source '$ident': missing collector '$collector' for type '$type'";
			return 0;
		}

		foreach $ident ( @$identref ) {
			my $len = length($ident);
			if ( $len < 1 || $len > 19 ) {
				print "Error Ident: '$ident': Source identifiers must be between 1 and 19 chars long!\n";
				return 0;
			}
			if ( $ident =~ /[^a-z0-9_\-]+/i ) {
				print "Error Ident: '$ident': Source identifiers must contain only characters [a-zA-Z0-9_-] !\n";
				return 0;
			}

			if ( exists $NfConf::sources{$ident}{'type'} && $NfConf::sources{$ident}{'type'} ne $type ) {
				print "\nError: $ident has different type than $$identref[0] for same collector.\n";
				return 0;
			}
			if ( scalar @$identref > 1 && !exists $NfConf::sources{$ident}{'IP'} ) {
				print "\nError: $ident missing parameter 'IP' for multiple sources collector.\n";
				return 0;
			}
			my $IP = $NfConf::sources{$ident}{'IP'};
		}
	}

	return 1;

} # End of ValidateSources

sub CheckReconfig {

	if ( !ValidateSources() ) {
		return 2;
	}
	# profile 'live' contains by definition all netflow sources currently in use.
	my %profileinfo = NfProfile::ReadProfile('live', '.');
	if ( $profileinfo{'status'} eq 'empty' ) {
		# it's an error reading this profile
		print STDERR "Error reading profile 'live'";
		if ( defined $Log::ERROR ) {
			print STDERR ": $Log::ERROR";
		}
		print STDERR "\n";
		return 2;
	}

	my @current_sources = NfProfile::ProfileChannels(\%profileinfo);
    my %_tmp;
    @_tmp{@current_sources} = 1;

	# Building source lists
	foreach my $source ( keys %NfConf::sources ) {
		if ( exists $_tmp{$source} ) {
			delete $_tmp{$source};
		} else {
			return 0;
		}
	}

	if ( scalar keys %_tmp > 0 ) {
		return 0;
	}

	return 1;

} # End of CheckReconfig

sub Reconfig {

	if ( scalar(keys %NfConf::sources) == 0 ) {
		print STDERR "Error: No sources defined!";
		return;
	}

	# profile 'live' contains by definition all netflow sources currently in use.
	my %profileinfo = NfProfile::ReadProfile('live', '.');
	if ( $profileinfo{'status'} eq 'empty' ) {
		# it's an error reading this profile
		print STDERR "Error reading profile 'live'";
		if ( defined $Log::ERROR ) {
			print STDERR ": $Log::ERROR";
		}
		print STDERR "\n";
		return;
	}

	my @current_sources = NfProfile::ProfileChannels(\%profileinfo);

    my %_tmp;
    @_tmp{@current_sources} = 1;

	# Building source lists
	my @AddSourceList;
	my @DeleteSourceList;
	foreach my $source ( sort keys %NfConf::sources ) {
		if ( exists $_tmp{$source} ) {
			delete $_tmp{$source};
		} else {
			push @AddSourceList, $source;
		}
	}
	@DeleteSourceList = keys %_tmp;

	# Nothing to do ?
	if ( (scalar @AddSourceList) == 0 && (scalar @DeleteSourceList) == 0 ) {
		print "Reconfig: No changes found!\n";
		$profileinfo{'locked'} = 0;
		if ( !NfProfile::WriteProfile(\%profileinfo) ) {
			print STDERR "Error writing profile 'live': $Log::ERROR\n";
		}
		return;
	}

	foreach my $source ( @AddSourceList ) {
		my $ret = NfSen::ValidFilename($source);
		if ( $ret ne "ok" ) {
			print STDERR "Error checking source name: $ret\n";
			return;
		}
	}

	# Confirm add/delete sources
	print "New sources to configure : ", join(' ', @AddSourceList), "\n" if scalar @AddSourceList;
	print "Remove configured sources: ", join(' ', @DeleteSourceList), "\n" if scalar @DeleteSourceList;
	if ( NfSen::UserInput("Continue?") ne 'y') {
		print "Faire enough! - Nothing changed!\n";
		$profileinfo{'locked'} = 0;
		if ( !NfProfile::WriteProfile(\%profileinfo) ) {
			print STDERR "Error writing profile 'live': $Log::ERROR\n";
		}
		return;
	}
	print "\n";

	my %StopCollectorList;
	my %StartCollectorList;
	my %AllCollectors;
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		push @{$AllCollectors{$port}}, $source;
	}


	# lock live profile
	%profileinfo = NfProfile::LockProfile('live', '.');
	if ( $profileinfo{'status'} eq 'empty' ) {
		# profile already locked and in use
		if ( $profileinfo{'locked'} == 1 ) {
			print STDERR "Profile 'live' is locked. Try later\n";
			return;
		}
	
		# it's an error reading this profile
		if ( defined $Log::ERROR ) {
			print STDERR "Error profile 'live': $Log::ERROR\n";
			return;
		}
	}

	# Add all new netflow sources
	if ( scalar @AddSourceList > 0 ) {
		# Add sources
		my $now = time();
		my $tstart = $now - ( $now % $NfConf::CYCLETIME );
		foreach my $source ( @AddSourceList ) {
			print "Add source '$source'";
			my $ret = NfProfile::AddChannel(\%profileinfo, $source, '+', 0, $NfConf::sources{$source}{'col'}, $source, []);
			if ( $ret eq "ok" ) {
				my $port = $NfConf::sources{$source}{'port'};
				# Do we need to start/restart a collector on that port?
				if ( NfSenRC::CollectorStatus($port) > 0 ) {
					# we already have a collector running - need to restart with new source added
					$StopCollectorList{$port}  = 1;	# mark to be started
					$StartCollectorList{$port} = 1; # mark to be stopped
				} else {
					# no collector is running - start a new one
					$StartCollectorList{$port} = 1;	# mark to be started
				}
			} else {
				print "Error while setting up channel '$source': $ret";
				print "No collector started! ";
			}
			print "\n";
		}
		print "\n";
	}

	# Delete sources, no longer configured
	if ( scalar @DeleteSourceList > 0 ) {
		print "Delete source(s): ", join(' ', @DeleteSourceList), ":\n";
		# Delete sources
		foreach my $source ( @DeleteSourceList ) {
			print "Delete source '$source' ";
			# Stop this collector if not already done
			my $port = $$NfSen::hints{'sources'}{$source};
			if ( NfSenRC::CollectorStatus($port) > 0 ) {
				# Properly stop collector before deleting the channel
				print "Stop running collector on port '$port' ";
				NfSenRC::StopCollector($port);
				$StopCollectorList{$port} = 2;	# mark as already stopped
			} 

			# Do we need to restart the collector on this for for other 
			# still existing sources?
			if ( exists $AllCollectors{$port} ) {
				$StartCollectorList{$port} = 1;	# mark to be started
			}

			my $ret = NfProfile::DeleteChannel(\%profileinfo, $source);
			if ( $ret ne "ok" ) {
				print "\nError while removing channel '$source': $ret\n";
			}
			print " \n";
		}
	}

	# Unlock/Write profile
	$profileinfo{'locked'} = 0;
	if ( !NfProfile::WriteProfile(\%profileinfo) ) {
		print STDERR "Error writing profile 'live': $Log::ERROR\n";
	}

	if ( !-f "$NfConf::PIDDIR/nfsend.pid") {
		# NfSen is not running - we are done
		print "Reconfig done!\n";
		delete $$NfSen::hints{'sources'};
		foreach my $source ( sort keys %NfConf::sources ) {
			$$NfSen::hints{'sources'}{$source} = $NfConf::sources{$source}{'port'};
		}
		return;
	}

	# Collector Jojo ...
	my $port;
	foreach $port ( keys %StopCollectorList ) {
		# Stop running collectors if not already done so
		if ( ($StopCollectorList{$port} == 1) && (NfSenRC::CollectorStatus($port) > 0) ) {
			print "Stop running collector on port '$port' ";
			NfSenRC::StopCollector($port);
		print "\n";
		}
	}
	foreach $port ( keys %StartCollectorList ) {
		if ( NfSenRC::CollectorStatus($port) > 0) {
			# Ups .. should not happen - something fishy!
			print STDERR "A collector on port '$port' is already running! Unclean reconfig\n";
			# give it another try to die
			NfSenRC::StopCollector($port);
		} 
		print "Start/restart collector on port '$port' for ";
		NfSenRC::StartCollector($port);
		print "\n";
	}

	print "\n";

	delete $$NfSen::hints{'sources'};
	foreach my $source ( sort keys %NfConf::sources ) {
		$$NfSen::hints{'sources'}{$source} = $NfConf::sources{$source}{'port'};
	}

	NfSenRC::NfSen_reload();

} # End of Reconfig

1;
