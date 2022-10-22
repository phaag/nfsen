#!%%PERL%%
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
#  $Id: NfProfile.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $

package NfProfile;

use strict;
use Sys::Syslog; 
use POSIX 'setsid';
use File::Find;
use Fcntl qw(:DEFAULT :flock);

use NfSen;
use NfSenRRD;
use Nfsync;
use Log;

our $PROFILE_VERSION = 130;	# version 1.3.0

my @ProfileKeys = (
	'description',	# Array of comment lines starting with '#'
	'name', 		# name of profile
	'group', 		# name of profile group
	'tbegin', 		# Begin of profile
	'tcreate', 		# Create time of profile
	'tstart', 		# Start time of profile data
	'tend', 		# End time of profile
	'updated',		# Time of last update 
	'expire',		# Max lifetime of profile data in hours 0 = no expire time
	'maxsize',		# Max size of profile in bytes	0 = no limit
	'size',			# Current size of profile in bytes
	'type',			# Profile type: 0: life, 1: history profile, 2: continuous profile
	'locked',		# somebody is working on this profile
	'status',		# status of profile
	'version',		# version of profile.dat
	'channel',		# array of ':' separated list of channel proprieties
);

my @ChannelKeys = (
	'first',
	'last',
	'size',
	'maxsize',
	'numfiles',
	'lifetime',
	'watermark',
	'status',
);

our @ChannelProperties = ( 'sign', 'colour', 'order', 'sourcelist' );

# Default profile description
my @ProfileTag = ( 
	"# \n",
);

my %LegacyProfileKeys = (
	'sourcelist' => 1,	# pre 1.3 parameter
	'filter',	 => 1	# pre 1.3 Name of filter file
);

local $SIG{'__DIE__'} = sub {
	my $message = shift;

	syslog("err","PANIC!: I'm dying: '$message'");

}; # End of __DIE__ 

my $EODATA 	= ".\n";

sub VerifyProfile {
	my $profile  	 = shift;
	my $profilegroup = shift;
	my $must_exists	 = shift;

	if ( !defined $profile ) {
		return "Missing profile name";
	}

	if ( defined $profilegroup && $profilegroup ne '.') {
		if ( $profilegroup =~ /[^A-Za-z0-9\-+_]+/ ) {
			return "Illegal characters in profile group name '$profilegroup'!\n";
		} 
	}

	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( $profile =~ /[^A-Za-z0-9\-+_]+/ ) {
		return "Illegal characters in profile name '$profile'!\n";
	} 
	if ( !$must_exists ) {
		return "ok";
	}

	if ( !-d "$NfConf::PROFILESTATDIR/$profilepath") {
		my $err_msg;
		if ( $profilegroup eq '.' ) {
			$err_msg = "Profile '$profile' does not exists\n";
		} else {
			$err_msg = "Profile '$profile' does not exists profile group '$profilegroup'\n";
		}
		return $err_msg;
	} 
	if ( !-f "$NfConf::PROFILESTATDIR/$profilepath/profile.dat") {
		return "Missing profile descriptor file of profile '$profile'\n";
	}

	return "ok"

} # End of VerifyProfile

sub ProfilePath {
	my $profile  = shift;
	my $profilegroup = shift;

	if ( !defined $profilegroup || $profilegroup eq '.' ) {
		return "$profile";
	} else {
		return "$profilegroup/$profile";
	}


} # End of ProfilePath

sub ChannelDecode {
	my $opts 	= shift;
	my $channel	= shift;

	my $c = $$opts{'channel'};

	my $profile = undef;
	my $profilegroup = undef;

	if ( $c =~ m#^([^/]+)/([^/]+)$# ) {
		$profile  = $1;
		$$channel = $2;
		$profilegroup = '.';
	} elsif ( $c =~ m#^([^/]+)/([^/]+)/([^/]+)$# ) {
		$profilegroup = $1;
		$profile  = $2;
		$$channel = $3;
	} else {
		$$channel = $c;
	}

	if ( defined $profile && ( exists $$opts{'profile'} || exists $$opts{'profilegroup'} ) ) {
		return "Ambiguous channel definition";
	}

	if ( defined $profile ) {
		$$opts{'profile'} 	   = $profile;
		$$opts{'profilegroup'} = $profilegroup;
	}
	return 'ok';

} # End of ChannelDecode

sub ProfileDecode {
	my $opts 		 = shift;
	my $profile 	 = shift;
	my $profilegroup = shift;

	if ( !exists $$opts{'profile'} ) {
		$$profile = undef;
		$$profilegroup = undef;
		return "Missing profile name";
	}

	my $_profile = $$opts{'profile'};

	if ( exists $$opts{'profilegroup'} ) {
		if ( $_profile =~ m#/# ) {
			$$profile = undef;
			$$profilegroup = undef;
			return "Ambiguous profile group";
		}
		$$profile 	   = $_profile;
		$$profilegroup = $$opts{'profilegroup'};
		return "ok";

	} else {
		if ( $_profile =~ m#^(.+)/([^/]+)$# ) {
			$$profilegroup = $1;
			$$profile 	   = $2;
		} else {
			$$profilegroup = ".";
			$$profile 	   = $_profile;
		}
		return "ok";
	}

} # End of ProfileDecode

sub ProfileExists {
	my $profile  = shift;
	my $profilegroup = shift;

	my $profilepath = ProfilePath($profile, $profilegroup);

	return -f "$NfConf::PROFILESTATDIR/$profilepath/profile.dat" ? 1 : 0;

} # End of ProfileExists

sub EmptyProfile {

	my %empty;
	# Make sure all fields are set
	foreach my $key ( @ProfileKeys ) {
		$empty{$key} = undef;
	}

	$empty{'description'}	= [];
	$empty{'name'}		= undef;
	$empty{'group'}		= '.';
	$empty{'tbegin'}	= 0;
	$empty{'tcreate'}	= 0;
	$empty{'tstart'}	= 0;
	$empty{'tend'}		= 0;
	$empty{'channel'}	= {};
	$empty{'updated'}	= 0;
	$empty{'expire'}	= 0;
	$empty{'maxsize'}	= 0;
	$empty{'size'}		= 0;
	$empty{'type'}		= 0;
	$empty{'locked'}	= 0;
	$empty{'status'}	= 'empty';
	$empty{'version'}	= 0;

	return %empty;

} # End of EmptyProfile

sub ProfileGroups {

	my @AllProfilesGroups;
	opendir(PROFILEDIR, "$NfConf::PROFILESTATDIR" ) or
		$Log::ERROR = "Can't open profiles directory: $!", 
		return @AllProfilesGroups;

	@AllProfilesGroups = grep { $_ !~ /^\.+/ &&  -d "$NfConf::PROFILESTATDIR/$_" && 
									-f "$NfConf::PROFILESTATDIR/$_/.group" } readdir(PROFILEDIR);

	closedir PROFILEDIR;

	unshift @AllProfilesGroups, '.';

	$Log::ERROR = undef;
	return sort @AllProfilesGroups;

} # End of ProfileGroups

sub ProfileList {
	my $profilegroup = shift;

	if ( !defined $profilegroup ) {
		$profilegroup = '.';
	}

	my @AllProfiles;
	opendir(PROFILEDIR, "$NfConf::PROFILESTATDIR/$profilegroup" ) or
		$Log::ERROR = "Can't open profile group directory: $!", 
		return @AllProfiles;

	@AllProfiles = grep {  -f "$NfConf::PROFILESTATDIR/$profilegroup/$_/profile.dat" && $_ !~ /^\./ && $_ ne 'live' && 
						  !-f "$NfConf::PROFILESTATDIR/$profilegroup/$_/.DELETED" } 
						readdir(PROFILEDIR);

	closedir PROFILEDIR;

	# make sure live is always listed first
	if ( $profilegroup eq '.' ) {
		unshift @AllProfiles, 'live';
	}
	$Log::ERROR = undef;
	return sort @AllProfiles;

} # End of ProfileList

sub DeleteDelayed {

	foreach my $profilegroup ( ProfileGroups() ) {
		my @AllProfiles;
		opendir(PROFILEDIR, "$NfConf::PROFILESTATDIR/$profilegroup" ) or
			$Log::ERROR = "Can't open profile group directory: $!", 
			return @AllProfiles;
	
		@AllProfiles = grep {  -f "$NfConf::PROFILESTATDIR/$profilegroup/$_/.DELETED" } 
							readdir(PROFILEDIR);
	
		closedir PROFILEDIR;

		# delete each profile
		foreach my $profile ( @AllProfiles ) {
			my $profilepath = ProfilePath($profile, $profilegroup);
			syslog('err', "Delete delayed: profile '$profile' in group '$profilegroup' ");

			my @dirs;
			push @dirs, "$NfConf::PROFILESTATDIR";
			if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
				push @dirs, "$NfConf::PROFILEDATADIR";
			}

			foreach my $dir ( @dirs ) {
				if ( !rename "$dir/$profilepath", "$dir/.$profile" ) {
					syslog('err', "Failed to rename profile '$profile' in group '$profilegroup' in order to delete: $!");
					next;
				} 

				my $command = "/bin/rm -rf $dir/.$profile &";
				system($command);
				if ( defined $main::child_exit && $main::child_exit != 0 ) {
					syslog('err', "Failed to execute command: $!\n");
					syslog('err', "system command was: '$command'\n");
				} 
			}
		}
	}

} # End of ProfileList


#
# Return an array of names of all channels in this profile
sub ProfileChannels {
	my $profileref = shift;

	return keys %{$$profileref{'channel'}}

} # End of ProfileChannels

sub ReadChannelStat {
	my $profilepath  = shift;
	my $channel		 = shift;

	my %channelstat;

	if ( ! -f "$NfConf::PROFILEDATADIR/$profilepath/$channel/.nfstat" ) {
		$Log::ERROR = "Channel info file missing for channel '$channel' in '$profilepath'",
		return ( 'empty' => 1 );
	}

	sysopen(CHANNELSTAT, "$NfConf::PROFILEDATADIR/$profilepath/$channel/.nfstat", O_RDONLY) or
		$Log::ERROR = "Can't open channel stat file for channel '$channel' in '$profilepath': $!",
		return ( 'empty' => 1 );

	flock CHANNELSTAT, LOCK_SH;
	while ( <CHANNELSTAT> ) {
		chomp;
		next if $_ =~ /^\s*$/;	# Skip empty lines
		
		my ($key, $value) = split /\s*=\s*/;
		if ( !defined $key ) {
			warn "Error reading channel stat information. Unparsable line: '$_'";
			$Log::ERROR = "Error reading channel stat information. Unparsable line: '$_'";
		} 

		$channelstat{$key} = $value;
	}
	foreach my $key ( @ChannelKeys ) {
		if ( !exists $channelstat{$key} ) {
			$Log::ERROR = "Error reading channel stat information. Missing key '$key'";
			return ( 'empty' => 1 );
		}
	}

	flock CHANNELSTAT, LOCK_UN;
	close CHANNELSTAT;

	return %channelstat;

} # End of ReadChannelStat

sub EmptyStat {
	my $statinfo = {};
	foreach my $db ( @NfSenRRD::RRDdb ) {
		$$statinfo{lc $db} = -1;
	}
	return $statinfo;

} # End of EmptyStat

sub ReadStatInfo {
	my $profileref	= shift;
	my $channel 	= shift;
	my $subdirs		= shift;
	my $tstart		= shift;
	my $tend		= shift;

	my $statinfo 	 = EmptyStat();
	my $name  		 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};
	
	my $profilepath = ProfilePath($name, $profilegroup);

	my $err = undef;
	my $args;
	if ( defined $tend ) {
		$args = "-I -R $NfConf::PROFILEDATADIR/$profilepath/$channel/$subdirs/nfcapd.$tstart:nfcapd.$tend";
	} else {
		$args = "-I -r $NfConf::PROFILEDATADIR/$profilepath/$channel/$subdirs/nfcapd.$tstart";
	}
	local $SIG{CHLD} = 'DEFAULT';
	if ( !open(NFDUMP, "$NfConf::PREFIX/nfdump $args 2>&1 |") ) {
		$err = $!;
		return ( $statinfo, 255, $err);
	} 
	my ( $label, $value );
	while ( my $line = <NFDUMP> ) {
		chomp $line;
		( $label, $value ) = split ':\s', $line;
		next unless defined $label;

		# we use everywhere 'traffic' instead of bytes
		$label =~ s/bytes/traffic/i;

		$$statinfo{lc $label} = $value;
	}

	my $nfdump_exit = 0;
	if ( !close NFDUMP ) {
		$nfdump_exit = $?;
		my $exit_value  = $nfdump_exit >> 8;
		my $signal_num  = $nfdump_exit & 127;
		my $dumped_core = $nfdump_exit & 128;
		if ( $exit_value == 250 ) {
			$err = "Failed get stat info for requested time slot";
		} else {
			$err = "Run nfdump failed: Exit: $exit_value, Signal: $signal_num, Coredump: $dumped_core";
		}
	};

	return ($statinfo, $nfdump_exit, $err);

} # End of ReadStatInfo

sub ReadRRDStatInfo {
	my $profileref	= shift;
	my $channel 	= shift;
	my $tstart		= shift;
	my $tend		= shift;


	$tstart = NfSen::ISO2UNIX($tstart);
	if ( ! defined $tend ) {
		$tend = $tstart;
	} else {
		$tend = NfSen::ISO2UNIX($tend);
	}

	my $statinfo 	 = EmptyStat();
	my $name  		 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};
	
	my $profilepath = ProfilePath($name, $profilegroup);

	my $RRDdb = "$NfConf::PROFILESTATDIR/$profilepath/$channel.rrd";
	my ($start,$step,$names,$data) = RRDs::fetch $RRDdb, "-s", $tstart-300, "-e", $tend-300, "MAX";
	my $err=RRDs::error;
	if ( defined $err ) {
		return ($statinfo, $err);
	}

	foreach my $line (@$data) {
		my $i = 0;
		foreach my $val (@$line) {
			if ( defined $val ) {
				$$statinfo{$$names[$i++]} += int($NfConf::CYCLETIME * $val);
			}
		}
	}

	return ($statinfo, $err);

} # End of ReadRRDStatInfo

sub GetPeakValues {
	my $profileref	= shift;
	my $whichtype	= shift;
	my $channellist	= shift;
	my $tinit		= shift;	# UNIX time format

	my $statinfo 	 = EmptyStat();
	my $name  		 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};
	
	my $profilepath = ProfilePath($name, $profilegroup);

	my $tmin = $tinit - 3600;
	if ( $tmin < $$profileref{'tstart'} ) {
		$tmin = $$profileref{'tstart'};
	}
	if ( $tmin > $tinit ) {
		return ( $tinit, "time outside profile time" );
	}
	my $tmax = $tmin + 2 * 3600;
	if ( $tmax > $$profileref{'tend'} ) {
		$tmax = $$profileref{'tend'};
	}
	if ( $tmax < $tinit ) {
		return ( $tinit, "time outside profile time" );
	}
	if ( $tmax < $tmin ) {
		return ( $tinit, "Can't select a time span");
	}

	my $max_sum_pos = 0;
	my $max_sum_neg = 0;
	my $sum_pos;
	my $sum_neg;
	my %sum_ref;
	my $tpos = $tinit;
	my $tneg = $tinit;
	my @AllChannels = split /\!/, $channellist;
	foreach my $ch ( @AllChannels ) {
		if ( $$profileref{'channel'}{$ch}{'sign'} eq '+' ) {
			$sum_ref{$ch} = \$sum_pos;
		} else {
			$sum_ref{$ch} = \$sum_neg;
		}
	}

	my $err = undef;
	for ( my $t=$tmin; $t<=$tmax; $t += $NfConf::CYCLETIME ) {
		$sum_pos = 0;
		$sum_neg = 0;
		my $subdirs = NfSen::SubdirHierarchy($t);

		my $tiso = NfSen::UNIX2ISO($t);
		foreach my $ch ( @AllChannels ) {
			my $args = "-I -r $NfConf::PROFILEDATADIR/$profilepath/$ch/$subdirs/nfcapd.$tiso";
	
			local $SIG{CHLD} = 'DEFAULT';
			if ( !open(NFDUMP, "$NfConf::PREFIX/nfdump $args 2>&1 |") ) {
				$err = $!;
				return ( $tinit, $err);
			} 
			my ( $label, $value );
			while ( my $line = <NFDUMP> ) {
				chomp $line;
				( $label, $value ) = split ':\s', $line;
				next unless defined $label;
		
				# we use everywhere 'traffic' instead of bytes
				$label =~ s/bytes/traffic/i;
				$label = lc $label;
				if ( $label eq $whichtype ) {
					${$sum_ref{$ch}} += $value;
				}
			}
		
			my $nfdump_exit = 0;
			if ( !close NFDUMP ) {
				$nfdump_exit = $?;
				my $exit_value  = $nfdump_exit >> 8;
				my $signal_num  = $nfdump_exit & 127;
				my $dumped_core = $nfdump_exit & 128;
				if ( $exit_value == 250 ) {
					$err = "Failed get stat info for requested time slot";
				} else {
					$err = "Run nfdump failed: Exit: $exit_value, Signal: $signal_num, Coredump: $dumped_core";
				}
				return ( $tinit, $err);
			}
		}
$tiso = NfSen::UNIX2ISO($t);
print ".t= $t $tiso, Sum+: $sum_pos, Sum-: $sum_neg\n";
		if ( $sum_pos > $max_sum_pos ) {
			$max_sum_pos = $sum_pos;
			$tpos = $t;
		}
		if ( $sum_neg > $max_sum_neg ) {
			$max_sum_neg = $sum_neg;
			$tneg = $t;
		}
	}
my $iso_tpos = NfSen::UNIX2ISO($tpos);
my $iso_tneg = NfSen::UNIX2ISO($tneg);
print ".Max+: $max_sum_pos at $iso_tpos, Max-: $max_sum_neg at $iso_tneg\n";
	if ( $max_sum_pos > $max_sum_neg ) {
		return ($tpos, undef );
	} else {
		return ($tneg, undef );
	}

} # End of GetPeakValues


#
# Returns the profile info hash, if successfull
# else returns EmptyProfile and sets Log::ERROR
sub ReadProfile {
	my $name  		 = shift;
	my $profilegroup = shift;

	# compat option, if an old plugin does not specify a profilegroup
	my $legacy = 0;
	if ( !defined $profilegroup ) {
		$profilegroup = '.';
		$legacy = 1;
	}

	my %profileinfo = EmptyProfile();
	my $description = [];

	$Log::ERROR	 = undef;
	my %empty	   = EmptyProfile();
	$empty{'name'}  = $name;
	$empty{'group'} = $profilegroup;
	
	my $profilepath = ProfilePath($name, $profilegroup);

	sysopen(ProFILE, "$NfConf::PROFILESTATDIR/$profilepath/profile.dat", O_RDONLY) or
		$Log::ERROR = "Can't open profile data file for profile: '$name' in group '$profilegroup': $!",
		return %empty;

	flock ProFILE, LOCK_SH;

	while ( <ProFILE> ) {
		chomp;
		next if $_ =~ /^\s*$/;	# Skip empty lines
		if ( $_ =~ /^\s*#\s*(.*)$/ ) {
			push @$description, "$1";
			next;
		}
		my ($key, $value) = split /\s*=\s*/;
		if ( !defined $key ) {
			warn "Error reading profile information. Unparsable line: '$_'";
			$Log::ERROR = "Error reading profile information. Unparsable line: '$_'";
		} 
		if ( !defined $value ) {
			warn "Error reading profile information. Empty value for line: '$_'";
		} 
		if ( exists $empty{"$key"} ) {
			if ( $key eq "channel" ) {
				my @_tmp = split /:/, $value;
				my $channelname = shift @_tmp;
				foreach my $prop ( @ChannelProperties ) {
					my $val = shift @_tmp;
					$profileinfo{'channel'}{$channelname}{$prop} = $val;
				}
			} else {
				$profileinfo{$key} = $value;
			}
		# this elsif needs the installer only
		} elsif ( exists $LegacyProfileKeys{"$key"} ) {
				$profileinfo{'legacy'}{$key} = $value;
		} else {
			warn "Error reading profile information. Unknown key: '$key'";
			$Log::ERROR =  "Error reading profile information. Unknown key: '$key'";
		}
	}
	$profileinfo{'description'} = $description;
	flock ProFILE, LOCK_UN;
	close ProFILE;

	# Make sure all fields are set
	foreach my $key ( @ProfileKeys ) {
		next if defined $profileinfo{$key};
		next if $key eq 'version';
		$profileinfo{$key} = $empty{$key};
		warn "Empty key '$key' in profile '$name' group '$profilegroup' - preset default value: $empty{$key}";
	}

	if ( $profileinfo{'name'} ne $name ) {
		$Log::ERROR = "Corrupt stat file. Needs to be rebuilded";
		return %empty;
	}

	if ( defined $Log::ERROR ) {
		return %empty;
	}

	if ( $legacy ) {
		$profileinfo{'sourcelist'} = join ':', keys %{$profileinfo{'channel'}};
	}
	return %profileinfo;

} # End of ReadProfile

#
# Returns the profile info hash, if successfull
# else if already locked, return EmptyProfile with 'locked' = 1
# else returns EmptyProfile and sets Log::ERROR
sub LockProfile {
	my $name = shift;
	my $profilegroup = shift;

	my %profileinfo = EmptyProfile();
	my $description = [];

	$Log::ERROR	= undef;
	my %empty	  = EmptyProfile();
	$empty{'name'} = $name;
	$empty{'group'} = $profilegroup;

	my $profilepath = ProfilePath($name, $profilegroup);

	sysopen(ProFILE, "$NfConf::PROFILESTATDIR/$profilepath/profile.dat", O_RDWR|O_BINARY) or
		$Log::ERROR = "Can't open profile data file for profile: '$name' in group '$profilegroup': $!",
		return %empty;

	flock ProFILE, LOCK_EX;

	while ( <ProFILE> ) {
		chomp;
		next if $_ =~ /^\s*$/;	# Skip empty lines
		if ( $_ =~ /^\s*#\s*(.*)$/ ) {
			push @$description, "$1";
			next;
		}
		my ($key, $value) = split /\s*=\s*/;
		if ( !defined $key ) {
			warn "Error reading profile information. Unparsable line: '$_'";
		} 
		if ( exists $empty{"$key"} ) {
			if ( $key eq "channel" ) {
				my @_tmp = split /:/, $value;
				my $channelname = shift @_tmp;
				foreach my $prop ( @ChannelProperties ) {
					my $val = shift @_tmp;
					$profileinfo{'channel'}{$channelname}{$prop} = $val;
				}
			} else {
				$profileinfo{$key} = $value;
			}
		} else {
			warn "Error reading profile information. Unknown key: '$key'";
		}
	}
	$profileinfo{'description'} = $description;

	# Make sure all fields are set
	foreach my $key ( @ProfileKeys ) {
		next if defined $profileinfo{$key};
		next if $key eq 'version';
		$profileinfo{$key} = $empty{$key};
		warn "Empty key '$key' in profile '$name' group '$profilegroup' - preset default value: $empty{$key}";
	}

	if ( $profileinfo{'name'} ne $name ) {
		flock ProFILE, LOCK_UN;
		close ProFILE;
		$Log::ERROR = "Corrupt stat file. Needs to be rebuilded";
		return %empty;
	}

	# Is it already locked?
	if ( $profileinfo{'locked'} ) {
		flock ProFILE, LOCK_UN;
		close ProFILE;
		$empty{'locked'} = 1;
		return %empty;
	}

	$profileinfo{'locked'} = 1;
	seek ProFILE, 0,0;

	foreach my $line ( @{$profileinfo{'description'}} ) {
		print ProFILE "# $line\n";
	}

	foreach my $key ( @ProfileKeys ) {
		next if $key eq 'description';
		next if $key eq 'channel';
		if ( !defined $profileinfo{$key} ) {
			print ProFILE "$key = \n";
		} else {
			print ProFILE "$key = $profileinfo{$key}\n";
		}
	}
	foreach my $channelname ( keys %{$profileinfo{'channel'}} ) {
		my @_properties;
		push @_properties, $channelname;
		foreach my $prop ( @ChannelProperties ) {
			push @_properties, $profileinfo{'channel'}{$channelname}{$prop};
		}
		print ProFILE "channel = ", join ':', @_properties, "\n";
	}
	my $fpos = tell ProFILE;
	truncate ProFILE, $fpos;

	flock ProFILE, LOCK_UN;
	if ( !close ProFILE ) {
		$Log::ERROR = "Failed to close profileinfo of profile '$name' in group '$profilegroup': $!.",
		return %empty;
	}

	return %profileinfo;

} # End of LockProfile

sub WriteProfile {
	my $profileref = shift;

	my $name  		 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};

	if ( length $name == 0 ) {
		$Log::ERROR = "While writing profile stat file. Corrupt data ref",
		return undef;
	}

	my $profilepath = ProfilePath($name, $profilegroup);

	$Log::ERROR = undef;
	sysopen(ProFILE, "$NfConf::PROFILESTATDIR/$profilepath/profile.dat", O_RDWR|O_CREAT) or
		$Log::ERROR = "Can't open profile data file for profile '$name' in group '$profilegroup': $!\n",
		return undef;

	flock ProFILE, LOCK_EX;
	seek ProFILE, 0,0;

	foreach my $line ( @{$$profileref{'description'}} ) {
		print ProFILE "# $line\n";
	}
	foreach my $key ( @ProfileKeys ) {
		next if $key eq 'description';
		next if $key eq 'channel';
		next if $key eq 'legacy';
		if ( !defined $$profileref{$key} ) {
			print ProFILE "$key = \n";
		} else {
			print ProFILE "$key = $$profileref{$key}\n";
		}
	}
	foreach my $channelname ( keys %{$$profileref{'channel'}} ) {
		my @_properties;
		push @_properties, $channelname;
		foreach my $prop ( @ChannelProperties ) {
			push @_properties, $$profileref{'channel'}{$channelname}{$prop};
		}
		print ProFILE "channel = ", join(':', @_properties), "\n";
	}

	my $fpos = tell ProFILE;
	truncate ProFILE, $fpos;

	flock ProFILE, LOCK_UN;
	if ( !close ProFILE ) {
		$Log::ERROR = "Failed to close profileinfo of profile '$name' in group '$profilegroup': $!.",
		return undef;
	}

	return 1;

} # End of WriteProfile


sub ProfileHistory {
	my $profileref = shift;

	my $name   = $$profileref{'name'};
	my $group  = $$profileref{'group'};
	my $tstart = $$profileref{'tstart'};
	my $tend   = $$profileref{'tend'};
	my $continous_profile = ($$profileref{'type'} & 3) == 2;

	my %liveprofile = ReadProfile('live', '.');
	if ( $tstart < $liveprofile{'tstart'} ) {
		syslog('warning', "live profile expired in requested start time.");
		syslog('warning', "Adjust start time from %s to %s.", 
			scalar localtime($tstart), scalar localtime($liveprofile{'tstart'}));
		$tstart = $liveprofile{'tstart'};
		if ( $tend < $tstart ) {
			syslog('err', "Error profiling history. tend now < tstart. Abort profiling");
			return;
		}
	}

	# we have to process that many time slices:
	my $numslices = ((( $tend - $tstart ) / $NfConf::CYCLETIME ) + 1 );
	
	$$profileref{'status'} = 'built 0';
	$$profileref{'locked'} = 1;
	if ( !WriteProfile($profileref) ) {
		syslog('err', "Error writing profile '$name': $Log::ERROR");
		return;
	}

	my $counter  = 0;
	my $progress = 0;
	my $percent  = $numslices / 100;

	my $channellist = join ':', keys %{$liveprofile{'channel'}};

	my $profilepath = ProfilePath($name, $group);
	my $subdirlayout = $NfConf::SUBDIRLAYOUT ? "-S $NfConf::SUBDIRLAYOUT" : "";
	my $arg = "-I -p $NfConf::PROFILEDATADIR -P $NfConf::PROFILESTATDIR $subdirlayout ";
	$arg   .= "-z " if $NfConf::ZIPprofiles;

	# create argument list specific for each channel
	# at the moment this contains of all channels in a continues profile
	my @ProfileOptList;
	foreach my $channel ( keys %{$$profileref{'channel'}} ) {
		push @ProfileOptList, "$group#$name#$$profileref{'type'}#$channel#$$profileref{'channel'}{$channel}{'sourcelist'}";
	}

	syslog('info', "ProfileHistory for profile '$name': $numslices time slices."),
	# Update the profile status every .1% of all slices, at least every 2 slices
	# more often does not makes senes
	my $modulo	 = int ($percent / 10) < 2 ? 2 : int ($percent / 10);
	my $profile_size = 0;
	my $t = $tstart; 
	while ( $t <= $tend ) {
		if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) {
			last;
		}

		my $iso = NfSen::UNIX2ISO($t);
		my $subdirs = NfSen::SubdirHierarchy($t);
		my %statinfo	= ();
		my $dsvector = join(':', @NfSenRRD::RRD_DS);

		my $flist = "-M $NfConf::PROFILEDATADIR/live/$channellist -r nfcapd.$iso";

		$counter++;
		my $completed = sprintf "%.1f%%", $counter / $percent;
		if ( $completed > 100 ) {
			$completed = 100;
		}
		if ( ($counter % $modulo ) == 0 ) {
			$$profileref{'status'} 	= "built $completed\n";
			$$profileref{'updated'} = $t;
			$$profileref{'size'} 	= $profile_size;
			WriteProfile($profileref);
			syslog('info', "Build Profile '$name':	 Completed: $completed\%"),
		}

		# run nfprofile but only for new profile $name
		#syslog('debug', "Run profiler: '$arg' '$flist'");
		if ( open NFPROFILE, "| $NfConf::PREFIX/nfprofile -t $t $arg $flist" ) {
			local $SIG{PIPE} = sub { syslog('err', "Pipe broke for nfprofile"); };
			foreach my $profileopts ( @ProfileOptList ) {
				print NFPROFILE "$profileopts\n";
				#syslog('debug', "profile opts: $profileopts");
			}
			close NFPROFILE;	# SIGCHLD sets $child_exit
		} 
	
		if ( $main::child_exit != 0 ) {
			syslog('err', "nfprofile failed: $!\n");
			syslog('debug', "System was: $NfConf::PREFIX/nfprofile $arg $flist");
			next;
		} 

		if ( ($$profileref{'type'} & 4 ) == 0 ) { # no shadow profile
			foreach my $channel ( keys %{$$profileref{'channel'}} ) {
				my $outfile = "$NfConf::PROFILEDATADIR/$profilepath/$channel/$subdirs/nfcapd.$iso";
	
				# array element 7 contains the size in bytes
				$profile_size +=(stat($outfile))[7];
			}
		}
		$t += $NfConf::CYCLETIME;
		if ( $continous_profile && $t == $tend ) {
			my %liveprofile = ReadProfile('live', '.');
			$tend = $liveprofile{'tend'};
			$$profileref{'tend'} = $tend;
		}
		if ( $$profileref{'maxsize'} && ( $profile_size > $$profileref{'maxsize'} )) {
			syslog('err', "Reached profile max size while building. Cancel building");
			open CANCELFLAG, ">$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
			close CANCELFLAG;
		}
		if ( $$profileref{'expire'} && ( $t - $tstart ) > $$profileref{'expire'}*3600 ) {
			syslog('err', "Reached profile max lifetime while building. Cancel building");
			open CANCELFLAG, ">$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
			close CANCELFLAG;
		}
	}
	if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) {
		syslog('info', "ProfileHistory: canceled."),
		# Canceled profiles become a history profile
		$$profileref{'tend'}    = $t;
		if ( ($$profileref{'type'} & 4) > 0 ) { # is shadow
			$$profileref{'type'}  = 1;
			$$profileref{'type'} += 4;
		} else {
			$$profileref{'type'} = 1;
		}
		unlink "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
	} else {
		syslog('info', "ProfileHistory: Done."),
	}

	$$profileref{'size'} 	= $profile_size;
	$$profileref{'updated'} = $tend;

	return $profile_size;

} # end of ProfileHistory

sub AddChannel {
	my $profileref 	= shift;
	my $channel 	= shift;
	my $sign		= shift;
	my $order		= shift;
	my $colour		= shift;
	my $sourcelist 	= shift;
	my $filter		= shift;	# array ref to lines for filter

	my $profile 	 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};
	my $profilepath  = ProfilePath($profile, $profilegroup);
	my $tstart		 = $$profileref{'tstart'};

	# name is already validated from calling routine

	# setup channel directory
	my $dir = "$NfConf::PROFILEDATADIR/$profilepath/$channel";
	mkdir "$dir" or
		return "Can't create channel directory: '$dir' $!\n";

	if ( !chmod 0775, $dir ) {
		rmdir "$dir";
		return "Can't chown '$dir': $! ";
	}
	if ( !chown $NfConf::UID, $NfConf::GID, $dir ) {
		rmdir "$dir";
		return "Can't chown '$dir': $! ";
	}

	if ( $profile ne 'live' || $profilegroup ne '.') {
		# setup channel filter
		my $filterfile = "$NfConf::PROFILESTATDIR/$profilepath/$channel-filter.txt";
	
		open(FILTER, ">$filterfile" ) or
			rmdir "$dir",
			return "Can't open filter file '$filter': $!";
	
		print FILTER map "$_\n", @$filter;
		close FILTER;
	}

	# Add channel to the top off the graph - search max_order
	my $max_order = 0;
	foreach my $ch ( keys %{$$profileref{'channel'}} ) {
		next unless $$profileref{'channel'}{$ch}{'sign'} eq $sign;
		$max_order++;
	}
	$max_order++;
	if ( ($order == 0) || ($order > $max_order) ) {
		$order = $max_order;
	}

	# reorder channels
	foreach my $ch ( keys %{$$profileref{'channel'}} ) {
		next unless $$profileref{'channel'}{$ch}{'sign'} eq $sign;
		if ( $$profileref{'channel'}{$ch}{'order'} >= $order ) {
			$$profileref{'channel'}{$ch}{'order'}++;
		}
	}

	$$profileref{'channel'}{$channel}{'sign'}   	= $sign;
	$$profileref{'channel'}{$channel}{'colour'} 	= $colour;
	$$profileref{'channel'}{$channel}{'order'}  	= $order;
	$$profileref{'channel'}{$channel}{'sourcelist'} = $sourcelist;

	# $tstart is the first value we need in the RRD DB, therefore specify 
	# $tstart - $NfConf::CYCLETIME ( 1 slot )
	NfSenRRD::SetupRRD("$NfConf::PROFILESTATDIR/$profilepath", $channel, $tstart - $NfConf::CYCLETIME, 1);
	if ( defined $Log::ERROR ) {
		rmdir "$NfConf::PROFILEDATADIR/$profilepath/$channel",
		unlink $filter;
		return "Creating RRD failed for channel '$channel': $Log::ERROR\n";
	}

	chown $NfConf::UID, $NfConf::GID, "$NfConf::PROFILESTATDIR/$profilepath/$channel.rrd";

	return "ok";

} # End of AddChannel

sub DeleteChannel {
	my $profileref = shift;
	my $channel = shift;

	my $profile 	 = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};
	my $profilepath  = ProfilePath($profile, $profilegroup);

	my $channelref   = $$profileref{'channel'}{$channel};
	
	# remove logically the channel from the profile
	delete $$profileref{'channel'}{$channel};

	if ( -d "$NfConf::PROFILEDATADIR/$profilepath/$channel" ) {
		# now remove physically the channel
		if ( !rename "$NfConf::PROFILEDATADIR/$profilepath/$channel", "$NfConf::PROFILEDATADIR/$profilepath/.$channel") {
			# restore channel to profile
			$$profileref{'channel'}{$channel} = $channelref;
			return "Failed to rename channel '$channel' in order to delete: $!\n";
		}
		system "/bin/rm -rf $NfConf::PROFILEDATADIR/$profilepath/.$channel";
	}

	# Delete RRD DB
	NfSenRRD::DeleteRRD("$NfConf::PROFILESTATDIR/$profilepath", $channel);

	# remove filter file
	unlink "$NfConf::PROFILESTATDIR/$profilepath/$channel-filter.txt";

	# Reorder the remaining channels
	my $sign 	= $$channelref{'sign'};
	my $order 	= $$channelref{'order'};
	foreach my $ch ( keys %{$$profileref{'channel'}} ) {
		next unless $$profileref{'channel'}{$ch}{'sign'} eq $sign;
		if ( $$profileref{'channel'}{$ch}{'order'} > $order ) {
			$$profileref{'channel'}{$ch}{'order'}--;
		}
	}


	my $is_shadow = ($$profileref{'type'} & 4) > 0 ;
	if ( !$is_shadow ) {
		# re-calculate size of profile
		my $profilesize = 0;
		my $tfirst 		= 0;
		foreach my $ch ( keys %{$$profileref{'channel'}} ) {
			my %channelinfo = ReadChannelStat($profilepath, $ch);
			if ( exists $channelinfo{'empty'} ) {
				next;
			}
			if ( $tfirst ) {
				if ( $channelinfo{'first'} < $tfirst ) {
					$tfirst = $channelinfo{'first'};
				}
			} else {
				$tfirst = $channelinfo{'first'};
			}
			$profilesize += $channelinfo{'size'};
		}
		$$profileref{'size'}   = $profilesize;
		$$profileref{'tstart'} = $tfirst if $tfirst;
	}

	return "ok";

} # End of DeleteChannel

sub GetProfilegroups {
	my $socket	= shift;
	my $opts 	= shift;

	foreach my $profilegroup ( ProfileGroups() ) {
		print $socket "_profilegroups=$profilegroup\n";
	}

	print $socket $EODATA;
	if ( defined $Log::ERROR ) {
		print $socket "ERR $Log::ERROR\n";
	} else {
		print $socket "OK Profile Listing\n";
	}


} # End of GetProfilegroups

sub DoRebuild {
	my $socket		 = shift;
	my $profileinfo  = shift;
	my $profile 	 = shift;
	my $profilegroup = shift;
	my $profilepath  = shift;
	my $installer	 = shift;
	my $DoGraphs	 = shift;

	# rebuilding live is a bit trickier to keep everything consistent
	# make sure, the periodic update process is done - then block cycles
	syslog('info', "Rebuilding profile '$profile', group '$profilegroup'");
	if ( $profile eq 'live' && $profilegroup eq '.' ) {
		syslog('debug', "Get lock");
		Nfsync::semwait();
	}

	# rebuild each channel, using nfexpire
	my $profilesize = 0;
	my $tstart		= 0;
	my $tend		= 0;
	my $args = "-Y -p -r $NfConf::PROFILEDATADIR/$profilepath";
	if ( open NFEXPIRE, "$NfConf::PREFIX/nfexpire $args 2>&1 |" ) {
		local $SIG{PIPE} = sub { syslog('err', "Pipe broke for nfexpire"); };
		while ( <NFEXPIRE> ) {
			chomp;
			# Option -Y returns an extra status line: 'Stat|<profilesize>|<time>'
			if ( /^Stat\|(\d+)\|(\d+)\|(\d+)/ ) {
				$profilesize = $1;
				$tstart		 = $2;
				$tend		 = $3;
			} else {
				s/%/%%/;
				syslog('debug', "nfexpire: $_");
			}
			syslog('debug', "nfexpire: $_") unless $installer;
		}
		close NFEXPIRE;	# SIGCHLD sets $child_exit
	} 

	if ( $main::child_exit != 0 ) {
		if ( $installer ) {
			return "nfexpire failed: $!";
		} else {
			syslog('err', "nfexpire failed: $!\n");
			syslog('debug', "System was: $NfConf::PREFIX/nfexpire $args");
		}
	} 

	$$profileinfo{'size'}	= $profilesize;
	$$profileinfo{'tstart'} = $tstart;
	$$profileinfo{'tend'} 	= $tend;
	$$profileinfo{'updated'}= $tend;
	
	if ( !$$profileinfo{'name'} ) {
		$$profileinfo{'description'} = \@ProfileTag;
		$$profileinfo{'name'}		 = $profile;
		$$profileinfo{'group'}		 = $profilegroup;

	} else {
		if ( $$profileinfo{'name'} ne $profile ) {
			syslog("warning", "Profile name missmatch - Set '$$profileinfo{'name'}' to '$profile'");
			$$profileinfo{'name'} 	= $profile;
			$$profileinfo{'group'}	= $profilegroup;
		}

	}

	$$profileinfo{'maxsize'} 	= defined $$profileinfo{'maxsize'} ? $$profileinfo{'maxsize'} + 0 : 0;
	$$profileinfo{'expire'} 	= defined $$profileinfo{'expire'} ? $$profileinfo{'expire'} + 0 : 0;

	# check order of profiles;
	my @CHAN = sort {
   		my $num1 = "$$profileinfo{'channel'}{$a}{'sign'}$$profileinfo{'channel'}{$a}{'order'}";
   		my $num2 = "$$profileinfo{'channel'}{$b}{'sign'}$$profileinfo{'channel'}{$b}{'order'}";
   		$num2 <=> $num1;
	} keys %{$$profileinfo{'channel'}};
			
	my @CHANpos;
	my @CHANneg;
			
	foreach my $channel ( @CHAN ) {
   		if ( $$profileinfo{'channel'}{$channel}{'sign'} eq "-" ) {
   			push @CHANneg, $channel;
   		} else {
   			unshift @CHANpos, $channel;
   		}
	}

	my $order = 1;
	foreach my $channel ( @CHANpos ) {
		if ( $$profileinfo{'channel'}{$channel}{'order'} != $order ) {
			syslog('info', "Fixing channel order for channel '$channel'. Was $$profileinfo{'channel'}{$channel}{'order'}, set to $order") unless $installer;
			$$profileinfo{'channel'}{$channel}{'order'} = $order;
		}
		$order++;
	}

	$order = 1;
	foreach my $channel ( @CHANneg ) {
		if ( $$profileinfo{'channel'}{$channel}{'order'} != $order ) {
			syslog('info', "Fixing channel order for channel '$channel'. Was $$profileinfo{'channel'}{$channel}{'order'}, set to $order") unless $installer;
			$$profileinfo{'channel'}{$channel}{'order'} = $order;
		}
		$order++;
	}

	# in case of rebuilding the graphs
	if ( $DoGraphs ) {
		syslog('info', "Rebuilding graphs");
		$$profileinfo{'status'} = 'rebuilding';
		$$profileinfo{'locked'} = 1;
		if ( !WriteProfile($profileinfo) ) {
			syslog('err', "Error writing profile '$profile': $Log::ERROR");
			return "Failed writing profile";
		}

		my $continous_profile = ($$profileinfo{'type'} & 3) == 2;

		syslog('info', "Setting up RRD DBs");
		foreach my $channel ( @CHAN ) {
			NfSenRRD::SetupRRD("$NfConf::PROFILESTATDIR/$profilepath", $channel, $tstart - $NfConf::CYCLETIME, 1);
		}

		my $numslices = ((( $tend - $tstart ) / $NfConf::CYCLETIME ) + 1 );
		my $percent  = $numslices / 100;
		my $counter  = 0;
		my $progress = 0;
		my $modulo	 = int ($percent * 10) < 2 ? 2 : int ($percent * 10);

		my $t;
		for ( $t = $tstart; $t <= $tend; $t += $NfConf::CYCLETIME ) {
			my $t_iso 	= NfSen::UNIX2ISO($t);
			foreach my $channel ( @CHAN ) {
				my $subdirs = NfSen::SubdirHierarchy($t);
				my ($statinfo, $exit_code, $err ) = ReadStatInfo($profileinfo, $channel, $subdirs, $t_iso, undef);
				my @_values = ();
				foreach my $ds ( @NfSenRRD::RRD_DS ) {
           			if ( !defined $$statinfo{$ds} || $$statinfo{$ds} == - 1 ) {
              			push @_values, 0;
          			} else {
               			push @_values, $$statinfo{$ds};
           			}
				}
				$err = NfSenRRD::UpdateDB("$NfConf::PROFILESTATDIR/$profilepath", $channel, $t,
						join(':',@NfSenRRD::RRD_DS) , join(':', @_values));
				if ( $Log::ERROR ) {
					syslog('err', "ERROR Update RRD time: '$t_iso', db: '$channel', profile: '$profile' group '$profilegroup' : $Log::ERROR");
				}
			}

			$counter++;
			my $completed = sprintf "%.1f%%", $counter / $percent;
			if ( $completed > 100 ) {
				$completed = 100;
			}
			if ( ($counter % $modulo ) == 0 ) {
				print $socket ".info Rebuilding Profile '$profile': Completed: $completed\%\n";
				syslog('info', "Rebuilding Profile '$profile': Completed: $completed\%");
			}


		}

		# history data is updated and we are done with history profiles
		# A continous profile except 'live' must be updated up to the current slot 
		# rebuilding the profile could have missed new slots -> profile missing slots
		if ( $continous_profile && ($profile ne 'live' || $profilegroup ne '.') ) {
			# get current current time slot
			my %liveprofile = ReadProfile('live', '.');
			$tend = $liveprofile{'tend'};

			# this can happen, if a history profile is switch back to continous
			# profile and wants to get updated now. Be sure we have all data
			if ( $t < $liveprofile{'tstart'} ) {
				$t = $liveprofile{'tstart'};
			}
			my $profile_size = $$profileinfo{'size'};

			# prepare profiler args 
			my @ProfileOptList;
			foreach my $channel ( keys %{$$profileinfo{'channel'}} ) {
				push @ProfileOptList, "$profilegroup#$profile#$$profileinfo{'type'}#$channel#$$profileinfo{'channel'}{$channel}{'sourcelist'}";
			}
			my $channellist = join ':', keys %{$liveprofile{'channel'}};
			my $subdirlayout = $NfConf::SUBDIRLAYOUT ? "-S $NfConf::SUBDIRLAYOUT" : "";
			my $arg = "-I -p $NfConf::PROFILEDATADIR -P $NfConf::PROFILESTATDIR $subdirlayout ";
			$arg   .= "-z " if $NfConf::ZIPprofiles;

			# profile missing slots
			if ( $t <= $tend ) {
				syslog('info', "Profiling missing slots");
			}
			while ( $t <= $tend ) {
				if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) {
					$$profileinfo{'status'} = 'canceled';
					syslog('info', "Rebuild canceled.");
					last;
				}

				my $iso = NfSen::UNIX2ISO($t);
				my $subdirs = NfSen::SubdirHierarchy($t);
				my %statinfo	= ();
				my $dsvector = join(':', @NfSenRRD::RRD_DS);
		
				my $flist = "-M $NfConf::PROFILEDATADIR/live/$channellist -r nfcapd.$iso";
		
				# run nfprofile for remaining slots
				#syslog('debug', "Run profiler: '$arg' '$flist'");
				if ( open NFPROFILE, "| $NfConf::PREFIX/nfprofile -t $t $arg $flist" ) {
					local $SIG{PIPE} = sub { syslog('err', "Pipe broke for nfprofile"); };
					foreach my $profileopts ( @ProfileOptList ) {
						print NFPROFILE "$profileopts\n";
						#syslog('debug', "profile opts: $profileopts");
					}
					close NFPROFILE;	# SIGCHLD sets $child_exit
				} 
			
				if ( $main::child_exit != 0 ) {
					syslog('err', "nfprofile failed: $!\n");
					syslog('debug', "System was: $NfConf::PREFIX/nfprofile $arg $flist");
					next;
				} 
		
				foreach my $channel ( keys %{$$profileinfo{'channel'}} ) {
					my $outfile = "$NfConf::PROFILEDATADIR/$profilepath/$channel/$subdirs/nfcapd.$iso";
		
					# array element 7 contains the size in bytes
					$profile_size +=(stat($outfile))[7];
				}
				$$profileinfo{'updated'} = $t;
				$$profileinfo{'tend'} 	 = $t;
				$$profileinfo{'size'} 	 = $profile_size;

				$t += $NfConf::CYCLETIME;
				%liveprofile = ReadProfile('live', '.');
				$tend = $liveprofile{'tend'};
			}
		}
	} else {
		syslog('info', "Graphs for profile '$profile', group '$profilegroup' not rebuilded");
	}

	if ( $profile eq 'live' && $profilegroup eq '.' ) {
		syslog('debug', "Release lock");
		Nfsync::semsignal();
	}

	syslog('info', "Rebuilding done.");

	# if we need to create the profile from
	# history data, lock the profile until down.
	$$profileinfo{'locked'} 		= 0;

	# state ok
	$$profileinfo{'status'} 		= 'OK';

	NfSenRRD::UpdateGraphs($profile, $profilegroup, $$profileinfo{'tend'}, 1);

	return 'ok';

} # End of DoRebuild

#
# Entry points for nfsend. All subs have a socket and an opts field as input parameters
sub GetAllProfiles {
	my $socket	= shift;
	my $opts 	= shift;

	foreach my $profilegroup ( ProfileGroups() ) {
		my @AllProfiles = ProfileList($profilegroup);
		if ( scalar @AllProfiles == 0 ) {
			# this groups no no profiles any longer - remove the directory
			# ignore errors as the last profile delete may still be in progress
			# however, the directories will be removed thereafter
			unlink "$NfConf::PROFILESTATDIR/$profilegroup/.group";
			unlink "$NfConf::PROFILEDATADIR/$profilegroup/.group";
			rmdir  "$NfConf::PROFILESTATDIR/$profilegroup";
			rmdir  "$NfConf::PROFILEDATADIR/$profilegroup";
		} else {
			foreach my $profile ( @AllProfiles ) {
				print $socket "_profiles=$profilegroup/$profile\n";
			}
		}
	}

	print $socket $EODATA;
	if ( defined $Log::ERROR ) {
		print $socket "ERR $Log::ERROR\n";
	} else {
		print $socket "OK Profile Listing\n";
	}

} # End of GetAllProfiles

#
sub GetProfile {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath  = ProfilePath($profile, $profilegroup);

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' in group '$profilegroup': $Log::ERROR\n";
		return;
	}

	# raw output format
	foreach my $key ( keys %profileinfo ) {
		next if $key eq 'channel';
		if ( $key eq 'description' ) {
			foreach my $line ( @{$profileinfo{$key}} ) {
				print $socket "_$key=$line\n";
			}
		} else {
			if ( !defined $profileinfo{$key} ) {
				warn "Undef for key '$key' in '$profile', '$profilegroup'";
			}
			print $socket  "$key=$profileinfo{$key}\n";
		}
	}
	my @CHAN = sort {
   		my $num1 = "$profileinfo{'channel'}{$a}{'sign'}$profileinfo{'channel'}{$a}{'order'}";
   		my $num2 = "$profileinfo{'channel'}{$b}{'sign'}$profileinfo{'channel'}{$b}{'order'}";
   		$num2 <=> $num1;
	} keys %{$profileinfo{'channel'}};

	foreach my $channel ( @CHAN ) {
		my @_properties;
		foreach my $prop ( @ChannelProperties ) {
			push @_properties, $profileinfo{'channel'}{$channel}{$prop};
		}

		print $socket "_channel=$channel:" , join(':', @_properties), "\n";
	}

	if ( -f "$NfConf::PROFILESTATDIR/$profilepath/flows-day.png" ) {
		print $socket "graphs=ok\n";
	} else {
		print $socket "graphs=no\n";
	}

	print $socket $EODATA;
	print $socket "OK Command completed\n";

} # End of GetProfile

#
sub GetStatinfo {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	if ( !exists $$opts{'channel'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing channel name!\n";
		return;
	}
	my $channel = $$opts{'channel'};

	if ( !exists $$opts{'tstart'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing time slot.\n";
		return;
	}

	my $tstart = $$opts{'tstart'};
	if ( !NfSen::ValidISO($tstart) ) {
		print $socket $EODATA;
		print $socket "ERR Unparsable time format '$tstart'!\n";
		return;
	}

	my $tend = undef;
	if ( exists $$opts{'tend'} ) {
		$tend = $$opts{'tend'};
		if ( !NfSen::ValidISO($tend) ) {
			print $socket $EODATA;
			print $socket "ERR Unparsable time format '$tend'!\n";
			return;
		}
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' in group '$profilegroup': $Log::ERROR\n";
		next;
	}

	if ( !exists $profileinfo{'channel'}{$channel} ) {
		print $socket $EODATA;
		print $socket "ERR channel '$channel' does not exists.\n";
		return;
	}
	my $subdirs = NfSen::SubdirHierarchy(NfSen::ISO2UNIX($tstart));

	# margin checks
	my $_tmp = NfSen::ISO2UNIX($tstart);
	if ( $_tmp < $profileinfo{'tstart'} ) {
		print $socket $EODATA;
		print $socket "ERR '$tstart' outside profile.\n";
		return;
	}
	if ( $_tmp > $profileinfo{'tend'} ) {
		print $socket $EODATA;
		print $socket "ERR '$tstart' beyond profile.\n";
		return;
	}
	if ( defined $tend ) {
		if ( $tend < $tstart ) {
			print $socket $EODATA;
			print $socket "ERR '$tend' before start time '$tstart'\n";
			return;
		}
		$_tmp = NfSen::ISO2UNIX($tend);
		if ( $_tmp > $profileinfo{'tend'} ) {
			print $socket $EODATA;
			print $socket "ERR '$tend' outside profile\n";
			return;
		}
	}

	my @LogBook;
	my ($statinfo, $exit_code, $err );
	if ( ($profileinfo{'type'} & 4 ) > 0 ) {
		# shadow profile
		# get mean values from RRD
		($statinfo, $err ) = ReadRRDStatInfo(\%profileinfo, $channel, $tstart, $tend);
		$exit_code = defined $err ? 1 : 0;
	} else {
		# get real values from files
		($statinfo, $exit_code, $err ) = ReadStatInfo(\%profileinfo, $channel, $subdirs, $tstart, $tend);
	}

	if ( $exit_code != 0 ) {
		print $socket $EODATA;
		print $socket "ERR $err\n";
		return;
	}

	foreach my $ds ( @NfSenRRD::RRD_DS ) {
	 	print $socket "$ds=$$statinfo{$ds}\n";
	}
	print $socket $EODATA;
	print $socket "OK command completed\n";

} # End of GetStatinfo

sub AddProfile {
	my $socket = shift;
	my $opts   = shift;

	# both options can be set at the same time
	my $history_profile	= 0;	# Profile start back in time; needs to be builded
	my $continuous_profile = 0;	# Profile continuous in time
	
	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 0);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	if ( ProfileExists($profile, $profilegroup) ) {
		print $socket $EODATA;
		print $socket "ERR profile '$profile' in group '$profilegroup' already exists\n";
		return;
	}

	my $profilepath = ProfilePath($profile, $profilegroup);

	# new profile must fit into live profile
	my %liveprofile = ReadProfile('live', '.');
	if ( $liveprofile{'status'} eq 'empty' ) {
		# Could not read live profile
		print $socket $EODATA;
		print $socket "ERR profile 'live': $Log::ERROR\n";	
		return;
	}

	my $now 	= time();
	my $tlast	= $liveprofile{'tend'};
	my $tstart	= $tlast;
	my $tend 	= $tstart;

	if ( exists $$opts{'tstart'} ) {
		$tstart = $$opts{'tstart'};
		if ( !NfSen::ValidISO($tstart) ) {
			print $socket $EODATA;
			print $socket "ERR Time format wrong '$tstart'!\n";
			return;
		}
		$tstart = NfSen::ISO2UNIX($tstart);
		if ( $tstart > $now ) {
			print $socket $EODATA;
			print $socket "ERR Profile start time in future: '$tstart'!\n";
			return;
		}
		$history_profile = 1;
	} else {
		# otherwise we have a ontinuous profile
		$continuous_profile = 1;
	}

	if ( exists $$opts{'tend'} ) {
		$tend = $$opts{'tend'};
		if ( !NfSen::ValidISO($tend) ) {
			print $socket $EODATA;
			print $socket "ERR Time format wrong '$tend'!\n";
			return;
		}
		$tend = NfSen::ISO2UNIX($tend);
		$history_profile = 1;
	} else {
		# otherwise we have a ontinuous profile
		$continuous_profile = 1;
	}

	if ( $history_profile && ($tstart < $liveprofile{'tstart'}) ) {
		print $socket $EODATA;
		print $socket "ERR '$$opts{'tstart'}' not within 'live' profile time window\n";
		return;
	}
	if ( $history_profile && ($tend > $liveprofile{'tend'}) ) {
		print $socket $EODATA;
		print $socket "ERR '$$opts{'tend'}' not within 'live' profile time window\n";
		return;
	}

	# prevent overflow to future timestamps
	$tend = $tlast if $tend > $tlast;	

	my $shadow_profile = exists $$opts{'shadow'} && $$opts{'shadow'} == 1;
	if ( $shadow_profile ) {
		$$opts{'expire'}  = 0;
		$$opts{'maxsize'} = 0;
	}

	# expire time
	my $lifetime   = exists $$opts{'expire'}  ? NfSen::ParseExpire($$opts{'expire'}) : 0;
	if ( $lifetime < 0 ) {
		print $socket $EODATA;
		print $socket "ERR Unknown expire time '$$opts{'expire'}'\n";
		return;
	}

	# max size
	my $maxsize	= exists $$opts{'maxsize'} ? NfSen::ParseMaxsize($$opts{'maxsize'}) : 0;
	if ( $maxsize < 0 ) {
		print $socket $EODATA;
		print $socket "ERR Unknown max size '$$opts{'maxsize'}'\n";
		return;
	}

	# All channel issues are done in AddProfileChannel

	# Do the work now:
	umask 0002;
	my @dirs;
	push @dirs, "$NfConf::PROFILESTATDIR";
	# if stat and data dirs differ
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		push @dirs, "$NfConf::PROFILEDATADIR";
	}

	foreach my $dir ( @dirs ) {
		# make sure profile group exists
		if ( !-d "$dir/$profilegroup" ) {
			if ( !mkdir "$dir/$profilegroup" ) {
				my $err = $!;
				syslog("err", "Can't create profile group directory '$dir/$profilegroup': $err");
				print $socket $EODATA;
				print $socket "ERR Can't create profile group directory '$dir/$profilegroup': $err!\n";
				return;
			}
			if ( !open TAGFILE, ">$dir/$profilegroup/.group" ) {
				my $err = $!;
				syslog("err", "Can't create profile group tag file '$dir/$profilegroup/.group': $err");
				print $socket $EODATA;
				print $socket "ERR Can't create profile group tag file '$dir/$profilegroup/.group': $err!\n";
				return;
			}
			close TAGFILE;
		} 

		if ( !mkdir "$dir/$profilepath" ) {
			my $err = $!;
			syslog("err", "Can't create profile directory '$dir/$profilepath': $err");
			print $socket $EODATA;
			print $socket "ERR Can't create profile directory '$dir/$profilepath': $err!\n";
			return;
		}

	}

	# Convert a one line description
	if ( exists $$opts{'description'} && ref $$opts{'description'} ne "ARRAY" ) {
		$$opts{'description'} = [ "$$opts{'description'}" ];
	}
	my %profileinfo;
	$profileinfo{'channel'} = {};
	
	$profileinfo{'description'}	= exists $$opts{'description'} ? $$opts{'description'} : \@ProfileTag;
	$profileinfo{'name'}		= $profile;
	$profileinfo{'group'}		= $profilegroup;
	$profileinfo{'tcreate'} 	= $now;
	$profileinfo{'tbegin'} 		= $tstart;
	$profileinfo{'tstart'} 		= $tstart;
	$profileinfo{'tend'} 		= $tend;

	# the first slot to be updated is 'updated' + $NfConf::CYCLETIME
	$profileinfo{'updated'}		= $tstart - $NfConf::CYCLETIME;	

	# expiring profiles makes only sense for continous profiles
	$profileinfo{'expire'} 		= $continuous_profile ? $lifetime : 0;
	$profileinfo{'maxsize'} 	= $continuous_profile ? $maxsize : 0;

	# the profile starts we 0 size
	$profileinfo{'size'} 		= 0;

	# continuous profile overwrites history profile
	$profileinfo{'type'} 		= 1 if $history_profile;
	$profileinfo{'type'} 		= 2 if $continuous_profile;
	$profileinfo{'type'} 		+= 4 if $shadow_profile;	# set bit 2 to mark profile as shadow profile
	
	# if we need to create the profile from
	# history data, lock the profile until done.
	$profileinfo{'locked'} 		= 0;

	# status of profile
	$profileinfo{'status'}		= 'new';

	# Version of profile
	$profileinfo{'version'}		= $PROFILE_VERSION;

	if ( !WriteProfile(\%profileinfo) ) {
		syslog('err', "Error writing profile '$profile': $Log::ERROR");
		print $socket $EODATA;
		print $socket "ERR writing profile '$profile': $Log::ERROR\n";
		# Even if we could not write the profile, try to delete the remains anyway
		DeleteProfile($socket, $opts);
	}
	
	print $socket $EODATA;
	print $socket "OK profile added\n";

} # End of AddProfile

sub AddProfileChannel {
	my $socket = shift;
	my $opts   = shift;

	# Parameter checking
	if ( !exists $$opts{'channel'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing channel name!\n";
		return;
	}
	my $channel;
	my $ret = ChannelDecode($opts, \$channel);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	my ($profile, $profilegroup);
	$ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	# profile live has a diffenrent procedure anyway
	if ( $profile eq 'live' && $profilegroup eq '.' ) {
		print $socket $EODATA;
		print $socket "ERR For profile '$profile', add channels in nfsen.conf and run nfsen reconfig !\n";
		return;
	}

	# validate name
	$ret = NfSen::ValidFilename($channel);
	if ( $ret ne "ok" ) {
		print $socket $EODATA;
		print $socket "ERR checking channel name: $ret!\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( exists $profileinfo{'channel'}{$channel} ) {
		print $socket $EODATA;
		print $socket "ERR channel '$channel' already exists.\n";
		return;
	}

	# Profile filter:
	# A given 'filter' overwrites the filter in the file 'filterfile'
	my $filter = [];
	if ( exists $$opts{'filter'} ) {
		$filter = $$opts{'filter'};
		# convert a one line filter
		if ( ref $filter ne "ARRAY" ) {
			$filter = [ "$filter" ];
		}
	} elsif ( exists $$opts{'filterfile'} ) {
		open(FILTER, $$opts{'filterfile'} ) or
			syslog('err', "Can't open filter file '$filter': $!"),
			print $socket $EODATA;
			print $socket "ERR Can't open filter file '$filter': $!\n",
			return;
		@$filter = <FILTER>;
		close FILTER;
	}
	if ( scalar @$filter == 0 ) {
		push @$filter, "not any\n";
	}
	my %out = NfSen::VerifyFilter($filter);
	if ( $out{'exit'} > 0 ) {
		print $socket $EODATA;
		print $socket "ERR Filter syntax error: ", join(' ', $out{'nfdump'}), "\n";
		return;
	}
	my $sourcelist;
	my %liveprofile = ReadProfile('live', '.');
	if ( exists $$opts{'sourcelist'} ) {
		$sourcelist = $$opts{'sourcelist'};
		while ( $sourcelist =~ s/\|\|/|/g ) {;}
		$sourcelist =~ s/^\|//;
		$sourcelist =~ s/\|$//;
		my @_list = split /\|/, $sourcelist;
		foreach my $source ( @_list ) {
			if ( !exists $liveprofile{'channel'}{$source} ) {
				print $socket $EODATA;
				print $socket "ERR source '$source' does not exist in profile live\n";
				return;
			}
		}
		$profileinfo{'channel'}{$channel}{'sourcelist'} = $sourcelist;
	} else {
		$sourcelist = join '|', keys %{$liveprofile{'channel'}};
	}

	%profileinfo = LockProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		if ( $profileinfo{'locked'} == 1 ) {
			print $socket $EODATA;
			print $socket "ERR Profile is locked!\n";
			return;
		}
	
		# it's an error reading this profile
		if ( defined $Log::ERROR ) {
			print $socket $EODATA;
			print $socket "ERR $Log::ERROR\n";
			syslog('err', "Error $profile: $Log::ERROR");
			return;
		}
	}

	my $colour = '#abcdef';
	my $sign   = '+';
	my $order  = 0;
	if ( exists $liveprofile{'channel'}{$channel} ) {
		$colour = $liveprofile{'channel'}{$channel}{'colour'};
		$sign   = $liveprofile{'channel'}{$channel}{'sign'};
	 	$order  = $liveprofile{'channel'}{$channel}{'order'};
	} 

	if ( exists $$opts{'colour'} ) {
		if ( $$opts{'colour'} !~ /^#[0-9a-f]{6}$/i ) {
			print $socket $EODATA;
			print $socket "ERR colour format error. Use '#dddddd'\n";
			return;
		} 
		$colour = $$opts{'colour'};
	} 

	if ( exists $$opts{'sign'} ) {
		if ( $$opts{'sign'} !~ /^[+\-]$/ ) {
			print $socket $EODATA;
			print $socket "ERR sign format error. Use '+' or '-'\n";
			return;
		} 
		$sign = $$opts{'sign'};
	}

	if ( exists $$opts{'order'} ) {
		if ( $$opts{'order'} !~ /^[0-9]+$/ ) {
			print $socket $EODATA;
			print $socket "ERR option format error: not a number\n";
			return;
		}
		$order = $$opts{'order'};
	}

	# Everything should be clear by now - so do the work
	$ret = AddChannel(\%profileinfo, $channel, $sign, $order, $colour, $sourcelist, $filter);

	$profileinfo{'locked'} 		= 0;
	if ( !WriteProfile(\%profileinfo) ) {
		DeleteProfileChannel($socket, $opts);
		$ret = "Can't update profile info: $Log::ERROR";
	}

	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR Add channel '$channel' failed: $ret\n";
	} else {
		print $socket $EODATA;
		print $socket "OK Channel '$channel' added.\n";
	}

} # End of AddProfileChannel

sub DeleteProfileChannel {
	my $socket = shift;
	my $opts   = shift;

	# Parameter checking
	my $channel;
	my $ret = ChannelDecode($opts, \$channel);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	my ($profile, $profilegroup);
	$ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	# profile live has a diffenrent procedure anyway
	if ( $profile eq 'live' && $profilegroup eq '.') {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile'. Delete channels in nfsen.conf and run nfsen reconfig !\n";
		return;
	}

	# validate name
	$ret = NfSen::ValidFilename($channel);
	if ( $ret ne "ok" ) {
		print $socket $EODATA;
		print $socket "ERR checking channel name: $ret!\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( !exists $$opts{'force'} && !exists $profileinfo{'channel'}{$channel} ) {
		print $socket $EODATA;
		print $socket "ERR channel '$channel' does not exists.\n";
		return;
	}

	%profileinfo = LockProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		if ( $profileinfo{'locked'} == 1 ) {
			print $socket $EODATA;
			print $socket "ERR Profile is locked!\n";
			return;
		}
	
		# it's an error reading this profile
		if ( defined $Log::ERROR ) {
			print $socket $EODATA;
			print $socket "ERR $Log::ERROR\n";
			syslog('err', "Error $profile: $Log::ERROR");
			return;
		}
	}

	if ( Nfsync::semnowait() ) {
		$ret = NfProfile::DeleteChannel(\%profileinfo, $channel);
		Nfsync::semsignal();
	} else {
		print $socket $EODATA;
		print $socket "ERR Can not delete the channel while a periodic update is in progress. Try again later.\n";
	}


	if ( scalar(keys %{$profileinfo{'channel'}}) == 0 ) {
		$profileinfo{'status'}	= 'stalled';
		$profileinfo{'tstart'} 	= $profileinfo{'updated'};
		$profileinfo{'tend'} 	= $profileinfo{'tstart'};
	}

	$profileinfo{'locked'} 		= 0;
	if ( !WriteProfile(\%profileinfo) ) {
		$ret = "Can't update profile info: $Log::ERROR";
	}

	if ( $ret eq 'ok' ) {
		# for the continuous profile
		print $socket $EODATA;
		print $socket "OK Channel '$channel' deleted.\n";
	} else {
		print $socket $EODATA;
		print $socket "ERR Delete channel '$channel' failed: $ret\n";
	}

} # End of DeleteProfileChannel

sub CancelProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( $profile eq 'live' && $profilegroup eq '.') {
		print $socket $EODATA;
		print $socket "ERR Don't want to delete profile 'live'!\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( ! -f "$NfConf::PROFILESTATDIR/$profilepath/.BUILDING" ) {
		print $socket $EODATA;
		print $socket "ERR No such build in progress\n";
		return;
	}

	open CANCELFLAG, ">$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
	close CANCELFLAG;

	print $socket $EODATA;
	print $socket "OK Building profile '$profile' canceled.\n";

} # End of CancelProfile


sub DeleteProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( $profile eq 'live' && $profilegroup eq '.') {
		print $socket $EODATA;
		print $socket "ERR Don't want to delete profile 'live'!\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		# Could not read live profile
		print $socket $EODATA;
		print $socket "ERR Profile '$profile': $Log::ERROR\n";	
		return;
	}
	if ( ! exists $$opts{'force'} && $profileinfo{'locked'} ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' is locked and can not be deleted now!\n";
		return;
	}
	if ( ! exists $$opts{'force'} && ( $profileinfo{'status'} ne 'OK' && $profileinfo{'status'} ne 'DELETED' )) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' is not in status 'OK' and can not be deleted now!\n";
		return;
	}
	%profileinfo = LockProfile($profile, $profilegroup);
	$profileinfo{'status'} = 'DELETED';
	WriteProfile(\%profileinfo);

	my @dirs;
	push @dirs, "$NfConf::PROFILESTATDIR";
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		push @dirs, "$NfConf::PROFILEDATADIR";
	}
	foreach my $dir ( @dirs ) {
		if ( !Nfsync::semnowait() ) {
			open DELFLAG, ">$NfConf::PROFILESTATDIR/$profilepath/.DELETED";
			print DELFLAG "profile deleted and to be removed later\n";
			close DELFLAG;
			print $socket $EODATA;
			print $socket "OK Profile '$profile' deleted.\n";
			return;
		}

		if ( !rename "$dir/$profilepath", "$dir/.$profile" ) {
			Nfsync::semsignal();
			print $socket $EODATA;
			print $socket "ERR Failed to rename profile '$profile' in group '$profilegroup' in order to delete: $!\n";
			return;
		} else {
			Nfsync::semsignal();
		}

		my $command = "/bin/rm -rf $dir/.$profile &";
		system($command);
		if ( defined $main::child_exit && $main::child_exit != 0 ) {
			syslog('err', "Failed to execute command: $!\n");
			syslog('err', "system command was: '$command'\n");
		} 
	}

	print $socket $EODATA;
	print $socket "OK Profile '$profile' deleted.\n";

} # End of DeleteProfile

sub ReGroupProfile {
	my $profileref = shift;
	my $newgroup   = shift;

	my $profile = $$profileref{'name'};
	my $profilegroup = $$profileref{'group'};

	if ( $profile eq 'live' && $profilegroup eq '.') {
		return "Don't want to move profile 'live'!\n";
	}

	if ( $$profileref{'status'} ne 'OK' ) {
		return "Profile '$profile' is not in status 'OK' and can not be moved now!\n";
	}

	my $profilepath	= ProfilePath($profile, $profilegroup);
	my $newprofilepath = ProfilePath($profile, $newgroup);
	if ( $profilepath eq $newprofilepath ) {
		return "ok";
	}

	if ( -d "$NfConf::PROFILESTATDIR/$newprofilepath" ) {
		return "An other profile with name '$profile' already exists in new group\n";
	}

	if ( !Nfsync::semnowait() ) {
		return "Can not rename the profile while a periodic update is in progress. Try again later.\n";
	}

	my @dirs;
	push @dirs, "$NfConf::PROFILESTATDIR";
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		push @dirs, "$NfConf::PROFILEDATADIR";
	}

	foreach my $dir ( @dirs ) {
		if ( ! -d "$dir/$newgroup" && !mkdir "$dir/$newgroup" ) {
			my $err = "Can't create new profile group directory '$NfConf::PROFILESTATDIR/$newgroup': $!";
			syslog("err", "$err");
			Nfsync::semsignal();
			return "$err\n";
		}
	
		if ( !open TAGFILE, ">$dir/$newgroup/.group" ) {
			my $err = $!;
			syslog("err", "Can't create profile group tag file '$dir/$newgroup/.group': $err");
			Nfsync::semsignal();
			return "Can't create profile group tag file '$dir/$newgroup/.group': $err!\n";
		}
		close TAGFILE;
	}

	if ( !rename "$NfConf::PROFILESTATDIR/$profilepath", "$NfConf::PROFILESTATDIR/$newprofilepath" ) {
		Nfsync::semsignal();
		return "Failed to rename profile '$profile': $!\n";
	} 
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		if ( !rename "$NfConf::PROFILEDATADIR/$profilepath", "$NfConf::PROFILEDATADIR/$newprofilepath" ) {
			# ohhh this is really bad! try to restore old profile stat dir
			rename "$NfConf::PROFILESTATDIR/$newprofilepath", "$NfConf::PROFILESTATDIR/$profilegroup";

			Nfsync::semsignal();
			return "Failed to rename profile '$profile': $!\n";
		} 
	}

	$$profileref{'group'} = $newgroup;
	Nfsync::semsignal();

	return 'ok';

} # End of ReGroupProfile


sub CommitProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath	= ProfilePath($profile, $profilegroup);
	# is this a new profile
	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} ne 'new' && $profileinfo{'status'} ne 'stalled' ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' not a new profile. Nothing to confirm.\n";	
		return;
	}

	if ( $profileinfo{'status'} eq 'stalled' && ($profileinfo{'type'} & 3 ) == 1  ) {
		# a stalled history profile does not make any sens to commit
		print $socket $EODATA;
		print $socket "ERR Can not commit stalled history profile.\n";	
		return;
	}

	# at least one channel need to exist
	if ( scalar keys(%{$profileinfo{'channel'}}) == 0 ) {
		print $socket $EODATA;
		print $socket "ERR No channels in profile '$profile'. At least one channels must exists.\n";	
		return;
	}

	my $now	= time();
	$now -= $now % $NfConf::CYCLETIME;

	if ( $profileinfo{'status'} eq 'stalled' ) {
		$profileinfo{'tstart'} 	= $now;
		$profileinfo{'tend'} 	= $profileinfo{'tstart'};
		$profileinfo{'updated'}	= $profileinfo{'tend'};
	}

	# if history data required
	if ( $profileinfo{'tstart'} <  $profileinfo{'tend'} ) { 	
		chdir '/';
		my $pid = fork;
		if ( !defined $pid ) {
			$Log::ERROR = $!;
			print $socket $EODATA;
			print $socket "ERR Can't fork: $Log::ERROR\n";
			return;
		}
		if ( $pid ) { 
			# we are the parent processs
			print $socket "pid=$pid\n";
			print $socket $EODATA;
			print $socket "OK Profiling netflow data\n";
			open PID, ">$NfConf::PROFILESTATDIR/$profilepath/.BUILDING" || 
				syslog('err', "Can't open pid file: $NfConf::PROFILESTATDIR/$profilepath/.BUILDING: $!");
			print PID "$pid\n";
			close PID;
			return;
		}
		setsid or die "Can't start a new session: $!";
		# the child starts to build the profile from history data
		close STDIN;
		close STDOUT;
		close $socket;

		# STDERR is tied too syslog. 
		untie *STDERR;
		close STDERR;

		open STDIN, '/dev/null'   || die "Can't read /dev/null: $!";
		open STDOUT, '>/dev/null' || die "Can't write to /dev/null: $!";
		open STDERR, '>/dev/null' || die "Can't write to /dev/null: $!";

		ProfileHistory(\%profileinfo);

		unlink "$NfConf::PROFILESTATDIR/$profilepath/.BUILDING";

		syslog('debug', "Graph update profile: $profile, Time: $profileinfo{'tend'}.");
		if ( NfSenRRD::UpdateGraphs($profile, $profilegroup, $profileinfo{'tend'}, 1) ) {
			syslog('err', "Error graph update: $Log::ERROR");
			$profileinfo{'status'}	= 'FAILED';	
		} else {
			$profileinfo{'status'}	= 'OK';	
		}

		# unlock profile
		$profileinfo{'locked'} 		= 0;
	
		WriteProfile(\%profileinfo);
		exit(0);

	}

	my $status;
	syslog('debug', "Graph update profile: $profile, Time: $profileinfo{'tend'}.");
	if ( NfSenRRD::UpdateGraphs($profile, $profilegroup, $profileinfo{'tend'}, 1) ) {
		syslog('err', "Error graph update: $Log::ERROR");
		$profileinfo{'status'}	= 'FAILED';	
		$status = "ERR $Log::ERROR\n";
	} else {
		$profileinfo{'status'}	= 'OK';	
		$status = "OK command completed\n";
	}

	# unlock profile
	$profileinfo{'locked'} 		= 0;

	WriteProfile(\%profileinfo);

	print $socket $EODATA;
	print $socket $status;
	return;

} # End of CommitProfile

sub ModifyProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath	= ProfilePath($profile, $profilegroup);
	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		# Could not read profile
		print $socket $EODATA;
		print $socket "ERR Profile '$profile': $Log::ERROR\n";	
		return;
	}

	my $continuous_profile = ($profileinfo{'type'} & 3) == 2 || $profileinfo{'type'} == 0;

	my $changed = 0;

	if ( exists $$opts{'description'} ) {
		$profileinfo{'description'} = $$opts{'description'};
		$changed = 1;
	}

	if ( exists $$opts{'locked'} ) {
		my $locked_opt = $$opts{'locked'};
		if ( $locked_opt !~ /^[01]$/ ) {
			print $socket $EODATA;
			print $socket "ERR Invalid value for option locked: '$locked_opt'. Use locked=0 or locked=1\n";
			return;
		}
		$profileinfo{'locked'} = 0 if $locked_opt == 0;
		$profileinfo{'locked'} = 1 if $locked_opt == 1;
		$changed = 1;
	}

	if ( exists $$opts{'status'} ) {
		my $status = $$opts{'status'};
		if ( $status !~ /^new$|^OK$|^FAILED$/ ) {
			print $socket $EODATA;
			print $socket "ERR Invalid value for option status: '$status'. Use 'new', 'OK' or 'FAILED'\n";
			return;
		}
		$profileinfo{'status'} = $status;
		$changed = 1;
	}

	if ( $continuous_profile ) {
		# these changes make only sense for continuous profiles
		# expire time
		if ( exists $$opts{'expire'} ) {
			my $lifetime   = NfSen::ParseExpire($$opts{'expire'});
			if ( $lifetime < 0 ) {
				print $socket $EODATA;
				print $socket "ERR Unknown expire time '$$opts{'expire'}'\n";
				return;
			}
			$profileinfo{'expire'} = $lifetime;
			$changed = 1;
		}
	
		# max size
		if ( exists $$opts{'maxsize'} ) {
 			my $maxsize = NfSen::ParseMaxsize($$opts{'maxsize'});
			if ( $maxsize < 0 ) {
				print $socket $EODATA;
				print $socket "ERR Unknown max size '$$opts{'maxsize'}'\n";
				return;
			}
			$profileinfo{'maxsize'}	= $maxsize;
			$changed = 1;
		}
	}

	if ( exists $$opts{'newgroup'} ) {
		my $newgroup = $$opts{'newgroup'};
		if ( $newgroup ne '.' && $newgroup =~ /[^A-Za-z0-9\-+_]+/ ) {
			print $socket $EODATA;
			print $socket "ERR Illegal characters in group name: '$newgroup'!\n";
			return;
		} 
		my $ret = ReGroupProfile(\%profileinfo, $newgroup);
		if ( $ret ne 'ok' ) {
			print $socket $EODATA;
			print $socket "ERR $ret\n";
			return;
		}
		$changed = 1;
	}

	if ( exists $$opts{'profile_type'} ) {
		my $new_type = $$opts{'profile_type'};
		if ( $new_type !~ /^\d$/ || $new_type == 0 || $new_type > 6 ) {
			print $socket $EODATA;
			print $socket "ERR Illegal profile type '$new_type'\n";
			return;
		}
		$new_type &= 7;
		
		my $current_shadow 	= ($profileinfo{'type'} & 4 ) > 0;
		my $current_type 	= $profileinfo{'type'} & 3;
		my $new_shadow 		= ($new_type & 4 ) > 0;
		$new_type 		= $new_type & 3;

print $socket ".current_shadow=$current_shadow\n";
print $socket ".current_type=$current_type\n";
print $socket ".new_shadow=$new_shadow\n";
print $socket ".new_type=$new_type\n";

		if ( $new_type == 0 ) {
			print $socket $EODATA;
			print $socket "ERR Illegal profile type '$new_type'\n";
			return;
		}

		my %liveprofile = ReadProfile('live', '.');
		if ( $liveprofile{'status'} eq 'empty' ) {
			# Could not read profile
			print $socket $EODATA;
			print $socket "ERR Profile 'live': $Log::ERROR\n";	
			return;
		}

		if ( $current_shadow == $new_shadow  ) {
			$profileinfo{'type'} = $new_type + ($new_shadow ? 4 : 0);
			$changed = 1;
print $socket ".Start/stop sequence only\n";	
		} else {
			if ( $new_shadow ) {
				# new shadow profile
print $socket ".New type is shadow\n";	
				foreach my $channel ( keys %{$profileinfo{'channel'}} ) {
					rename "$NfConf::PROFILEDATADIR/$profilepath/$channel", "$NfConf::PROFILEDATADIR/$profilepath/.$channel";
					system "/bin/rm -rf $NfConf::PROFILEDATADIR/$profilepath/.$channel &";
					mkdir "$NfConf::PROFILEDATADIR/$profilepath/$channel";
				}
				# use start of graph for new value of profile start time
				$profileinfo{'tstart'} = $profileinfo{'tbegin'};
print $socket ".Set profile first $profileinfo{'tstart'}\n";	
				$profileinfo{'size'} 	= 0;
				$profileinfo{'expire'} 	= 0;
				if ( $new_type == 2 && $profileinfo{'tstart'} < $liveprofile{'tstart'} ) {
					$profileinfo{'tstart'} = $liveprofile{'tstart'};
print $socket ".Adjust cont profile tstart to live profile tstart $liveprofile{'tstart'}\n";	
				}
				if ( $profileinfo{'tstart'} > $profileinfo{'tend'} ) {
					$profileinfo{'tstart'} = $profileinfo{'tend'};
				}
				$changed = 1;
			} else {
				# new real profile		
print $socket ".New type is real\n";	
				if ( $new_type == 2 ) {
					my $now = time();
					$profileinfo{'tstart'} = $now - ( $now % $NfConf::CYCLETIME );
				} else {
					print $socket $EODATA;
					print $socket "ERR Can not convert to history profile - no data available\n";	
					return;
				}
			}
			$profileinfo{'type'} = $new_type + ($new_shadow ? 4 : 0);
			$changed = 1;
		}
	}
	
	if ( $changed ) {
		if ( !WriteProfile(\%profileinfo) ) {
			syslog('err', "Error writing profile '$profile': $Log::ERROR");
			print $socket $EODATA;
			print $socket "ERR writing profile '$profile': $Log::ERROR\n";
		}
		print $socket $EODATA;
		print $socket "OK profile modified\n";
	} else {
		print $socket $EODATA;
		print $socket "OK Nothing modified\n";
	}

} # End of ModifyProfile

sub ModifyProfileChannel {
	my $socket = shift;
	my $opts   = shift;

	# Parameter checking

	my $channel;
	my $ret = ChannelDecode($opts, \$channel);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	my ($profile, $profilegroup);
	$ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath = ProfilePath($profile, $profilegroup);

	# validate name
	$ret = NfSen::ValidFilename($channel);
	if ( $ret ne "ok" ) {
		print $socket $EODATA;
		print $socket "ERR checking channel name: $ret!\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);

	# we can handle the option: sign, colour, ( color ), order
	if ( exists $$opts{'color'} ) {
		$$opts{'colour'} = $$opts{'color'};
	}

	my $changed = 0;
	if ( exists $$opts{'colour'} ) {
		if ( $$opts{'colour'} !~ /^#[0-9a-f]{6}$/i ) {
			print $socket $EODATA;
			print $socket "ERR Invalid value for option colour: '$$opts{'colour'}'. Use colour=#aabbcc\n";
			return;
		}
		$profileinfo{'channel'}{$channel}{'colour'} = $$opts{'colour'};
		$changed = 1;
	}

	my $max_pos  = 0;
	my $max_neg  = 0;
	my $maxorder = 0;;
	foreach my $ch ( keys %{$profileinfo{'channel'}} ) {
		if ( $profileinfo{'channel'}{$ch}{'sign'} eq '+' ) {
			$max_pos++;
		}
		if ( $profileinfo{'channel'}{$ch}{'sign'} eq '-' ) {
			$max_neg++;
		}
	}

	if ( exists $$opts{'sign'} ) {
print $socket ".sign: +:$max_pos, -:$max_neg\n";

		if ( $$opts{'sign'} !~ /^[+\-]$/ ) {
			print $socket $EODATA;
			print $socket "ERR Invalid value for option sign: '$$opts{'sign'}'. Use sign=+ or sign=-\n";
			return;
		}
		# if new sign is different from old sign, remove channel from old list, reorder list and 
		# put the channel at the tail of the new list, increasing the number of elements in new list
		if ( $profileinfo{'channel'}{$channel}{'sign'} ne $$opts{'sign'} ) {

print $socket ".Change sign from $profileinfo{'channel'}{$channel}{'sign'} to $$opts{'sign'}\n";

			# re-order channels, closing the gap
			foreach my $ch ( keys %{$profileinfo{'channel'}} ) {
				if ( $profileinfo{'channel'}{$ch}{'sign'} eq $profileinfo{'channel'}{$channel}{'sign'} &&
					 $profileinfo{'channel'}{$ch}{'order'} > $profileinfo{'channel'}{$channel}{'order'} ) {
					$profileinfo{'channel'}{$ch}{'order'}--;
				}
			}
			$profileinfo{'channel'}{$channel}{'sign'}  = $$opts{'sign'};
			$profileinfo{'channel'}{$channel}{'order'} = $$opts{'sign'} eq '+' ? ++$max_pos : ++$max_neg;

			$changed = 1;
		} # else nothing to do 
else {
print $socket ".Nothing to do\n";
}
	}

	if ( exists $$opts{'order'} ) {
		$maxorder = $profileinfo{'channel'}{$channel}{'sign'} eq '+'  ? $max_pos : $max_neg;;
		if ( $$opts{'order'} !~ /^[0-9]+$/ || $$opts{'order'} > $maxorder) {
			print $socket $EODATA;
			print $socket "ERR Invalid value for option order: '$$opts{'order'}'. Use order=1..$maxorder\n";
			return;
		}

		# in case of '0' put channel at the end of the list
		if ( $$opts{'order'} == 0 ) {
			$$opts{'order'} = $maxorder;
		}

		if ( $profileinfo{'channel'}{$channel}{'order'} != $$opts{'order'} ) {
			my $old_order = $profileinfo{'channel'}{$channel}{'order'};
			my $new_order = $$opts{'order'};

			# re-order the channels
			foreach my $ch ( keys %{$profileinfo{'channel'}} ) {
				# only channels with same sign are affected
				next unless $profileinfo{'channel'}{$ch}{'sign'} eq $profileinfo{'channel'}{$channel}{'sign'};

				if ( $new_order > $old_order ) {
					next if $profileinfo{'channel'}{$ch}{'order'} > $new_order;
					next if $profileinfo{'channel'}{$ch}{'order'} < $old_order;
					$profileinfo{'channel'}{$ch}{'order'}--;
				} else {
					next if $profileinfo{'channel'}{$ch}{'order'} < $new_order;
					next if $profileinfo{'channel'}{$ch}{'order'} > $old_order;
					$profileinfo{'channel'}{$ch}{'order'}++;
				}

			}

			# set new order of channel
			$profileinfo{'channel'}{$channel}{'order'} = $$opts{'order'};

			$changed = 1;
		} # else nothing to do
	}

	if ( exists $$opts{'sourcelist'} ) {
		if ( $profile eq "live" ) {
			print $socket $EODATA;
			print $socket "ERR Can't modify sourcelist in profile 'live'.\n";
			return;
		}
		my %liveprofile = ReadProfile('live', '.');
		my $sourcelist = $$opts{'sourcelist'};
		while ( $sourcelist =~ s/\|\|/|/g ) {;}
		$sourcelist =~ s/^\|//;
		$sourcelist =~ s/\|$//;
		my @_list = split /\|/, $sourcelist;
		foreach my $source ( @_list ) {
			if ( !exists $liveprofile{'channel'}{$source} ) {
				print $socket $EODATA;
				print $socket "ERR source '$source' does not exist in profile live\n";
				return;
			}
		}
		$profileinfo{'channel'}{$channel}{'sourcelist'} = $sourcelist;
		$changed = 1;
	}
	if ( exists $$opts{'filter'} ) {
		if ( $profile eq "live" ) {
			print $socket $EODATA;
			print $socket "ERR Can't modify filter in profile 'live'.\n";
			return;
		}
		my $filter = $$opts{'filter'};
		# convert single line filter
		if ( ref $filter ne "ARRAY" ) {
			$filter = [ "$filter" ];
		}
		my %out = NfSen::VerifyFilter($filter);
		if ( $out{'exit'} > 0 ) {
			print $socket $EODATA;
			print $socket "ERR Filter syntax error: ", join(' ', $out{'nfdump'}), "\n";
			return;
		}
		my $filterfile = "$NfConf::PROFILESTATDIR/$profilepath/$channel-filter.txt";
print $socket ".filterfile: $filterfile\n";
		if ( !open(FILTER, ">$filterfile" ) ) {
			print $socket $EODATA;
			print $socket "ERR Can't open filter file: $!\n";
			return;

		}
		print FILTER join "\n", @$filter;
		print FILTER "\n";
		close FILTER;

		$changed = 1;
	}

	if ( $changed ) {
		if ( !WriteProfile(\%profileinfo) ) {
			syslog('err', "Error writing profile '$profile': $Log::ERROR");
			print $socket $EODATA;
			print $socket "ERR writing profile '$profile': $Log::ERROR\n";
		}

		if ( NfSenRRD::UpdateGraphs($profile, $profilegroup, $profileinfo{'tend'}, 1) ) {
			syslog('err', "Error graph update: $Log::ERROR");
			$profileinfo{'status'}	= 'FAILED';	
		} else {
			$profileinfo{'status'}	= 'OK';	
		}

		print $socket $EODATA;
		print $socket "OK profile modified\n";
	} else {
		print $socket $EODATA;
		print $socket "OK Nothing modified\n";
	}

} # End of ModifyProfileChannel

sub RebuildProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath = ProfilePath($profile, $profilegroup);

	my %profileinfo = ReadProfile($profile, $profilegroup);
	if ( $profileinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile': $Log::ERROR\n";
		return;
	}

	if ( $profileinfo{'status'} eq 'new' ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' is a new profile.\n";
		return;
	}

	if ( ($profileinfo{'type'} & 4) > 0  ) {
		print $socket $EODATA;
		print $socket "ERR Profile '$profile' is a shadow profile.\n";
		return;
	}

	%profileinfo = LockProfile($profile, $profilegroup);
	if (  $profileinfo{'status'} eq 'empty' ) {
		if ( $profileinfo{'locked'} == 1 ) {
			print $socket $EODATA;
			print $socket "ERR Profile '$profile' is already locked. Can't rebuild now\n";
		} else {
			print $socket $EODATA;
			print $socket "ERR Profile '$profile': $Log::ERROR\n";	
		}
		return;
	}

	my $RebuildGraphs = exists $$opts{'all'} ? 1 : 0;
		
	syslog('info', "Start to rebuild profile '$profile'");

	my $status = DoRebuild($socket, \%profileinfo, $profile, $profilegroup, $profilepath, 0, $RebuildGraphs);

	if ( !WriteProfile(\%profileinfo) ) {
		syslog('err', "Error writing profile '$profile': $Log::ERROR");
		print $socket $EODATA;
		print $socket "ERR writing profile '$profile': $Log::ERROR\n";
		return;
	}

	print $socket $EODATA;
	if ( $status ne 'ok' ) {
		print $socket "ERR $status\n";

	} else {
		print $socket "OK profile rebuilded\n";
	}

} # End of RebuildProfile

sub ExpireProfile {
	my $socket	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	my %profileinfo = LockProfile($profile, $profilegroup);
	# Make sure profile is not empty - means it exists and is not locked
	if ( $profileinfo{'status'} eq 'empty' ) {
		if ( $profileinfo{'locked'} == 1 ) {
			print $socket $EODATA;
			print $socket "ERR Profile is locked!\n";
			syslog('info', "Profile is locked. Can't expire");
			return;
		}
	
		# it's an error reading this profile
		if ( defined $Log::ERROR ) {
			print $socket $EODATA;
			print $socket "ERR $Log::ERROR\n";
			syslog('err', "Error $profile: $Log::ERROR");
			return;
		}
	}

	my $is_shadow = ($profileinfo{'type'} & 4) > 0 ;
	# history profiles do not want to be expired
	if ( ($profileinfo{'type'} & 3) == 1 || $is_shadow ) {
		$profileinfo{'locked'} = 0;
		if ( !WriteProfile(\%profileinfo) ) {
			syslog('err', "Error writing profile '$profile': $Log::ERROR");
		}
		syslog('info', "Can't expire history or shadow profile");
		print $socket $EODATA;
		print $socket "ERR Can't expire history profile\n";
		return;
	}

	syslog('info', "Force expire for profile '$profile'");


	my $tstart			= $profileinfo{'tstart'};
	my $profilesize 	= $profileinfo{'size'};

	my $args = "-Y -p -e $NfConf::PROFILEDATADIR/$profile -w $NfConf::low_water ";
	$args .= "-s $profileinfo{'maxsize'} " if $profileinfo{'maxsize'};
	my $_t = 3600*$profileinfo{'expire'}; 
	$args .= "-t $_t "  if defined $profileinfo{'expire'};

	if ( open NFEXPIRE, "$NfConf::PREFIX/nfexpire $args 2>&1 |" ) {
		local $SIG{PIPE} = sub { syslog('err', "Pipe broke for nfexpire"); };
		while ( <NFEXPIRE> ) {
			chomp;
			if ( /^Stat|(\d+)|(\d+)/ ) {
				$profilesize = $1;
				$tstart		 = $2;
			}
			syslog('debug', "nfexpire: $_");
		}
		close NFEXPIRE;	# SIGCHLD sets $child_exit
	} 

	if ( $main::child_exit != 0 ) {
		syslog('err', "nfexpire failed: $!\n");
		syslog('debug', "System was: $NfConf::PREFIX/nfexpire $args");
		next;
	} 

	$profileinfo{'size'}	= $profilesize;
	$profileinfo{'tstart'} 	= $tstart;

	$profileinfo{'locked'} = 0;
	if ( !WriteProfile(\%profileinfo) ) {
		syslog('err', "Error writing profile '$profile': $Log::ERROR");
	}

	syslog('info', "End force expire");

	print $socket $EODATA;
	print $socket "OK profile expired\n";

} # End of ExpireProfile


sub GetChannelfilter {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	
	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( !exists $$opts{'channel'} ) {
		print $socket $EODATA;
		print $socket "ERR profile and channel required.\n";
		return;
	}
	my $channel	= $$opts{'channel'};

	my $channeldir = "$NfConf::PROFILEDATADIR/$profilepath/$channel";
	if ( ! -d $channeldir ) {
		print $socket $EODATA;
		print $socket "ERR no such channel\n";
		return;
	}

	if ( $profile eq 'live' ) {
		print $socket "_filter=any\n";
		print $socket $EODATA;
		print $socket "OK Command completed\n";
	} else {
		my $filterfile = "$NfConf::PROFILESTATDIR/$profilepath/$channel-filter.txt";

		if ( open(FILTER, "$filterfile" ) ) {
			while ( <FILTER> ) {
				chomp;
				print $socket "_filter=$_\n";
			}
			print $socket $EODATA;
			print $socket "OK Command completed\n";
		} else {
			print $socket $EODATA;
			print $socket "ERR Error reading filter - $!\n";
		}
		close FILTER;
	}

} # End of GetChannelfilter

sub GetChannelstat {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( !exists $$opts{'channel'} ) {
		print $socket $EODATA;
		print $socket "ERR profile and channel required.\n";
		return;
	}

	my %profileinfo = ReadProfile($profile, $profilegroup);
	my $is_shadow = ($profileinfo{'type'} & 4) > 0 ;
	if ( $is_shadow ) {
		print $socket $EODATA;
		print $socket "ERR Profile is a shadow profile.\n";
		return;
	}
	my %channelinfo = ReadChannelStat($profilepath, $$opts{'channel'});
	if ( defined $Log::ERROR ) {
		print $socket $EODATA;
		print $socket "ERR $Log::ERROR\n";
		return;
	}
	foreach my $key ( keys %channelinfo ) {
		print "$key=$channelinfo{$key}\n";
	}
	print $socket $EODATA;
	print $socket "OK Command completed\n";

} # End of GetChannelstat

sub SendPicture {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 
	my $profilepath = ProfilePath($profile, $profilegroup);

	if ( !exists $$opts{'picture'} ) {
		print $socket $EODATA;
		print $socket "ERR picture required.\n";
		return;
	}
	my $picture = $$opts{'picture'};
	sysopen(PIC, "$NfConf::PROFILESTATDIR/$profilepath/$picture", O_RDONLY) or
		print $socket $EODATA,
		print $socket "ERR Can't open picture file: $!",
		return;

	my $buf;
	while ( sysread(PIC, $buf, 1024)) {
		syswrite($socket, $buf, length($buf));
	}
	close PIC;

} # End of SendPicture

sub GetDetailsGraph {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	my %profileinfo = ReadProfile($profile, $profilegroup);

	if ( !exists $$opts{'arg'} ) {
		print $socket $EODATA;
		print $socket "ERR details argument list required.\n";
		return;
	}
	my $detailargs = $$opts{'arg'};
	$ret = NfSenRRD::GenDetailsGraph(\%profileinfo, $detailargs);
	if ( $ret ne "ok" ) {
		syslog('err', "Error generating details graph: $ret");
	}

} # End of GetDetailsGraph

sub SearchPeak {
	my $socket 	= shift;
	my $opts 	= shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		print $socket $EODATA;
		print $socket "ERR $ret\n";
		return;
	} 

	if ( !exists $$opts{'channellist'} ) {
		print $socket $EODATA;
		print $socket "ERR channel list required.\n";
		return;
	}
	my $channellist = $$opts{'channellist'};

	my %profileinfo = ReadProfile($profile, $profilegroup);
	my @AllChannels = split /\!/, $channellist;
	foreach my $channel ( @AllChannels ) {
		if ( !exists $profileinfo{'channel'}{$channel} ) {
			print $socket $EODATA;
			print $socket "ERR channel '$channel' does not exists in profile '$profilegroup/$profile'\n";
			return;
		}
	}
	
	if ( !exists $$opts{'tinit'} ) {
		print $socket $EODATA;
		print $socket "ERR time slot required.\n";
		return;
	}
	my $tinit = $$opts{'tinit'};
	if ( !NfSen::ValidISO($tinit) ) {
		print $socket $EODATA;
		print $socket "ERR Unparsable time format '$tinit'!\n";
		return;
	}

	if ( !exists $$opts{'type'} ) {
		print $socket $EODATA;
		print $socket "ERR type of graph required.\n";
		return;
	}
	my $type = $$opts{'type'};
	my ($t, $p ) = split /_/, $type;
	if ( not defined $t ) {
		print $socket $EODATA;
		print $socket "ERR type of graph required.\n";
		return;
	}

	my %DisplayProto = ( 'any' => 1, 'TCP' => 1, 'UDP' => 1, 'ICMP' => 1, 'other' => 1 );
	my %DisplayType	 = ( 'flows' => 1, 'packets' => 1, 'traffic' => 1);
	if ( !exists $DisplayProto{$p} || !exists $DisplayType{$t} ) {
		print $socket $EODATA;
		print $socket "ERR type '$type' unknown.\n";
		return;
	}
	$type =~ s/_any//;

	my ( $tmax, $err) = GetPeakValues(\%profileinfo, lc $type, $channellist, NfSen::ISO2UNIX($tinit));

	if ( defined $err ) {
		print $socket $EODATA;
		print $socket "ERR $err\n";
	} else {
		$tmax=NfSen::UNIX2ISO($tmax);
		print $socket "tpeek=$tmax\n";
		print $socket $EODATA;
		print $socket "OK command completed\n";
	}
	return;

} # End of SearchPeak

sub CompileFileArg {
	my $opts 	  = shift;
	my $argref	  = shift;
	my $filterref = shift;

	my ($profile, $profilegroup);
	my $ret = ProfileDecode($opts, \$profile, \$profilegroup);
	if ( $ret ne 'ok' ) {
		return "$ret";
	} 

	$ret = VerifyProfile($profile, $profilegroup, 1);
	if ( $ret ne 'ok' ) {
		return "$ret";
	} 

	my %profileinfo = ReadProfile($profile, $profilegroup);

	if ( !exists $$opts{'srcselector'} ) {
		return "srcselector list required";
	}
	my $srcselector = $$opts{'srcselector'};

	foreach my $channel ( split ':', $srcselector ) {
		if ( !exists $profileinfo{'channel'}{$channel} ) {
			return "Requested channel '$channel' does not exists in '$profilegroup/$profile'";
		}
	}

	if ( !exists $$opts{'type'} ) {
		return "profile type required\n";
	}
	my $type = $$opts{'type'};

	my $profilepath = ProfilePath($profile, $profilegroup);
	if ( $type eq 'real' ) {
		$$argref = "-M $NfConf::PROFILEDATADIR/$profilepath/$srcselector ";
		return "ok";
	}

	# flow processing for shadow profiles is more complicated:
	# we need first to rebuild the channel filter for each channel selected and then apply the requested filter
	if ( $type eq 'shadow' ) {
		# compile directory list 
		my %Mdir;
		foreach my $channel ( split ':', $srcselector ) {
			my %identlist = ();
			foreach my $channel_source ( split /\|/, $profileinfo{'channel'}{$channel}{'sourcelist'} ) {
				$Mdir{"$channel_source"} = 1;
				$identlist{"$channel_source"} = 1;
			}
			push @$filterref, "( ident " . join(' or ident ', keys %identlist) . ") and (";
			my $filterfile = "$NfConf::PROFILESTATDIR/$profilepath/$channel-filter.txt";
	
			open(FILTER, "$filterfile" ) or
				return "Can't open filter file '$filterfile': $!";
			my @_tmp = <FILTER>;
			close FILTER;
			chomp(@_tmp);
			push @$filterref, @_tmp;

			push @$filterref, ")";
			push @$filterref, "or";
		}
		# remove last 'or'
		pop @$filterref;
		# shadow profiles will access live data
		$$argref = "-M $NfConf::PROFILEDATADIR/live/" . join (':', keys %Mdir);

		return "ok";
	}

	return "unknown type $type.\n";
	
} # End of CompileFileArg

sub CancelBuilds {

	foreach my $profilegroup ( ProfileGroups() ) {
		my @AllProfiles;
		opendir(PROFILEDIR, "$NfConf::PROFILESTATDIR/$profilegroup" ) or
			$Log::ERROR = "Can't open profile group directory: $!", 
			return @AllProfiles;
	
		@AllProfiles = grep {  -f "$NfConf::PROFILESTATDIR/$profilegroup/$_/.BUILDING" } 
							readdir(PROFILEDIR);
	
		closedir PROFILEDIR;

		# delete each profile
		foreach my $profile ( @AllProfiles ) {
			my $profilepath = ProfilePath($profile, $profilegroup);
			syslog('err', "Cancel building profile '$profile' in group '$profilegroup' ");
			open CANCELFLAG, ">$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
			close CANCELFLAG;
			my $i = 0;
			while ( ($i < 60) && -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) {
				sleep(1);
				$i++;
			}
			if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) { 
				syslog('err', "Cancel building profile '$profile' in group '$profilegroup' did not succeed! Abort waiting!");
			}
		}
	}

} # End of CancelBuilds

sub CheckProfiles {

	foreach my $profilegroup ( ProfileGroups() ) {
		my @AllProfiles = ProfileList($profilegroup);
		foreach my $profile ( @AllProfiles ) {
			my $profilepath = ProfilePath($profile, $profilegroup);
			my %profileinfo = ReadProfile($profile, $profilegroup);
			if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.BUILDING" ) {
				syslog('err', "Clean-up debris profile '$profile' in group '$profilegroup' ");
				unlink "$NfConf::PROFILESTATDIR/$profilepath/.BUILDING";
				$profileinfo{'tend'} = $profileinfo{'updated'};
				if ( ($profileinfo{'type'} & 4) > 0 ) { # is shadow
					$profileinfo{'type'}  = 1;
					$profileinfo{'type'} += 4;
				} else {
					$profileinfo{'type'} = 1;
				}
				my $status = DoRebuild(\%profileinfo, $profile, $profilegroup, $profilepath, 0, 0);
				syslog('err', "Rebuilded profile '$profile' in group '$profilegroup': $status ");
			}
			if ( -f "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED" ) {
				syslog('err', "Clean-up debris profile '$profile' in group '$profilegroup' ");
				unlink "$NfConf::PROFILESTATDIR/$profilepath/.CANCELED";
				if ( ($profileinfo{'type'} & 4) > 0 ) { # is shadow
					$profileinfo{'type'}  = 1;
					$profileinfo{'type'} += 4;
				} else {
					$profileinfo{'type'} = 1;
				}
				my $status = DoRebuild(\%profileinfo, $profile, $profilegroup, $profilepath, 0, 0);
				syslog('err', "Rebuilded profile '$profile' in group '$profilegroup': $status ");
			}
			if ( $profileinfo{'locked'} ) {
				syslog('err', "Clean-up debris profile '$profile' in group '$profilegroup' ");
				$profileinfo{'locked'} = 0;
			} 
			if ( !WriteProfile(\%profileinfo) ) {
				syslog('err', "Error writing profile '$profile' in group '$profilegroup' ");
			}
		}
	}



} # End of CheckProfiles

1;


