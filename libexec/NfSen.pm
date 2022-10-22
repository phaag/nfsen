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
#  $Id: NfSen.pm 71 2017-01-19 16:16:21Z peter $
#
#  $LastChangedRevision: 71 $

package NfSen;

use strict;
use POSIX qw(strftime);
use File::Find;
use Time::Local;
use Sys::Syslog; 
use NfSenRRD;
use Log;
use Fcntl qw(:DEFAULT :flock);
use Storable qw(lock_store lock_retrieve);

my $EODATA 	= ".\n";

our $hints;

sub ValidFilename {
	my $filename = shift;

	if ( $filename !~ /[A-Za-z0-9\-,_]/ ) {
 		return "Invalid name: RRD allowed characters: A-Z, a-z, 0-9, -,_ "
	}

# RRD vname is limited to to chars above.
#	if ( $filename =~ m#[/\\\s:"*?<>;|]# ) {
#		return "Name must not contain any '/' ';', ':', '|'";
#	}
	if ( $filename =~ m#^\.# ) {
		return "Name must not start with '.'";
	}

	return "ok"

} # End of ValidFilename

sub ValidEmail($) {
    my $email = shift;

    if ( $email =~ /^[a-z0-9_\.-]+\@([a-z0-9_-]+\.){1,}[a-z]{2,4}$/i ||
        $email =~ /^[a-z0-9_\.-]+\@localhost$/i ) {
        return 1;
    } else {
        return 0;
    }
} # End of ValidEmail

#
# Parse Expire string:
# Valid format:
#	<num> d|day|days	number of days
#	<num> h|hour|hours	number of hours
#	<num>				number of hours
# any combination of days and hours is valid
# returns the number of hours ( days converted to hours )
# for new expire value. '0' for no expire value
# -1 if parsing string failed.
sub ParseExpire {
	my $expire = shift;
	
	$expire = lc $expire;
	$expire =~ s/day[s]{0,1}/d/;
	$expire =~ s/hour[s]{0,1}/h/;
	$expire =~ s/^\s*(\d+)\s*$/$1h/;

	my $lifetime = undef;	# Get overwritten if a valid value is found

	my ( $value ) = $expire =~ /(\d+)\s*d\b/i;
	if ( defined $value ) {
		$lifetime = 24 * $value;
	} 
	( $value ) = $expire =~ /(\d+)\s*h\b/i;
	if ( defined $value ) {
		$lifetime = defined $lifetime ? $lifetime + $value : $value;
	}

	return defined $lifetime ? $lifetime : -1;

} # End of ParseExpire


#
# Parse Max size string:
# Valid format:
#	<num> k|kb			number of KB for profile
#	<num> m|mb			number of MB for profile
#	<num> g|gb			number of GB for profile
#	<num> t|tb			number of TB for profile
#	<num>				number of MB for profile
# returns the number of bytes for the profile.
# '0' for no expire value
# -1 if parsing string failed.
sub ParseMaxsize {
	my $maxsize = shift;

	$maxsize = lc $maxsize;
	$maxsize =~ s/^\s*(\d+\.{0,1}\d*)\s*$/$1m/;
	my ($value, $scale) = $maxsize =~ /\s*(\d+\.{0,1}\d*)\s*([kmgt]{1})b{0,1}\b/;
	if ( defined $value ) {
		$value *= 1024 if $scale eq 'k';
		$value *= 1024 * 1024 if $scale eq 'm';
		$value *= 1024 * 1024 * 1024 if $scale eq 'g';
		$value *= 1024 * 1024 * 1024 * 1024 if $scale eq 't';
	} else {
		$value = -1;
	}

	return $value;
} # End of ParseMaxsize

#
# Tests string for a valid date.
# Dates are recongized valid between 1.1.1970 00:00 and 19.1.2038 14:14
#	The date may include '-' for better readability
#	Format: yyyymmddHHmm, yyyy-mm-dd-HH-MM
sub ValidISO {
	my $time = shift;

	# strinp '-' chars
	$time =~ s/\-//g;

	# any non - number char is invalid
	return 0 if $time =~ /[^\d]+/;

	# outside required timeframe
	return 0 if $time < 197001010000 || $time > 203801191414;

	return 1;

} # End of ValidISO

#
# Convert a a UNIX time value into ISO format yyyymmddHHMM
sub UNIX2ISO {
	my $time = shift;

    my @tmp 	= localtime($time);
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($time);

	$year += 1900;
	my $tstring = $year;
	$mon++;
	$tstring	.= $mon  < 10 ? "0" . $mon  : $mon;
	$tstring	.= $mday < 10 ? "0" . $mday : $mday;
	$tstring	.= $hour < 10 ? "0" . $hour : $hour;
	$tstring	.= $min  < 10 ? "0" . $min  : $min;

    return $tstring;

} # End of UNIX2ISO

#
# Create a more readable value scaled in TB, GB, MB, and KB
sub ScaledBytes {
	my $value = shift;

	my $scale = 1024 * 1024 * 1024 * 1024;
	if ( $value >=  $scale ) {
		return sprintf "%.1f TB", $value / $scale;
	} elsif ( $value >= ( $scale /= 1024 ) ) {
		return sprintf "%.1f GB", $value / $scale;
	} elsif ( $value >= ( $scale /= 1024 ) ) {
		return sprintf "%.1f MB", $value / $scale;
	} elsif ( $value >=  1024 ) {
		return sprintf "%.1f KB", $value / 1024;
	} else {
		return "$value";
	}

} # End of ScaledBytes

# Convert a an ISO time value into UNIX format
sub ISO2UNIX {
	my $isotime = shift;

	if ( !ValidISO($isotime) ) {
		return 0;
	}

	$isotime =~ s/\-//g;	# allow '-' to structur time string

    # 2004 02 13 12 45 /
	my $sec = 0;
	my ( $year, $mon, $mday, $hour, $min ) = $isotime =~ /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/;
	$mon--;

	# round down to nearest 5 min slot
	my $diff = $min % 5;
	if ( $diff ) {
		$min -= $diff;
	}

	my $unixtime = Time::Local::timelocal($sec,$min,$hour,$mday,$mon,$year);

    return $unixtime;

} # End of ISO2UNIX

sub SubdirHierarchy {
	my $t 		= shift;	# UNIX time format

	my $layout	= $NfConf::SUBDIRLAYOUT;

	if ( !defined $layout || $layout == 0 ) {
		return '';
	}

	my @subdir_def = (
		"",
		"%Y/%m/%d",
		"%Y/%m/%d/%H",
		"%Y/%W/%u",
		"%Y/%W/%u/%H",
		"%Y/%j",
		"%Y/%j/%H",
		"%F",
		"%F/%H"
	);

	if ( $layout > $#subdir_def ) {
		return undef;
	}

	return strftime $subdir_def[$layout], localtime($t);

} # End of SubdirHierarchy

sub root_process {

	my $run_as   = $<;
	my ($login,$pass,$root_id,$gid) = getpwnam('root');

	return $run_as == $root_id;

} # End of root_process

sub DropPriv {
	my $requested_user = shift;

	$Log::ERROR = undef;
	if ( !defined $requested_user ) {
		$requested_user = $NfConf::USER;
	}

	my $run_as  = $<;

	my ($login,$pass,$nf_uid,$gid) = getpwnam($NfConf::USER);
	if ( !defined $login ) {
		$Log::ERROR = "NFSEN user '$NfConf::USER' not found on this system";
		return undef;
	}

	# when our uid == configured netflow user uid
	if ( $run_as == $nf_uid ) {
		return 1;
	}

	my $www_gid;
	if ( defined $NfConf::WWWGROUP ) {
		if ( ! ($www_gid  = getgrnam($NfConf::WWWGROUP)) ) {
			$Log::ERROR = "NFSEN group '$NfConf::WWWGROUP' not found on this system";
			return undef;
		}
	}

	# we can change our uid/gid only as root
	if ( !root_process() ) {
		$Log::ERROR = "Want to run as user 'root', '$NfConf::USER' or '$NfConf::WWWUSER'. Current uid is '$run_as'";
		return undef;
	}

	$( = $www_gid;
	$) = "$www_gid $(";

	$> = $< = $nf_uid;

	if( $> != $nf_uid ){
		$Log::ERROR = "Couldn't become uid \"$nf_uid\"";
		return undef;
	}
	my @groups = split ' ', $);

	if( $www_gid != shift @groups ){
		$Log::ERROR = "Couldn't become gid \"$www_gid\"";
		return undef;
	}
	# print "Priv: $nf_uid, $www_gid\n";

	return 1;

} # End of DropPriv

#
# Verify a given nfdump filter
# If filter syntax ok, returns an assoc array with key 'exit'
# equals zero, otherwise 'exit' value is positive, and
# error messages are found as an array in 'nfdump' value.
sub VerifyFilter {
	my $filterref = shift;

	my @out;
	my %res;

	my @_tmp;
	foreach my $line ( @$filterref ) {
		next if $line =~ /^\s*#/;

		if ( $line =~ /(.+)#/ ) {
			push @_tmp, $1;
		} else {
			push @_tmp, $line;
		}

	}

	my $filterstr = join "\n", @_tmp;

	if ( $filterstr =~ /[^\s!-~\n]+/ || $filterstr =~ /['"`;\\]/ ) {
		push @out, "Illegal characters in filter: '$&'";
    $res{'nfdump'} = @out;
    $res{'exit'} = 127;
    return %res;
	}

	$filterstr =~ s/^[\s\t\n]+//;
	$filterstr =~ s/[\s\t\n]+$//;
	if ( $filterstr eq '' ) {
		push @out, "Empty filter";
    $res{'nfdump'} = @out;
    $res{'exit'} = 127;
    return %res;
	}

	if ( !open(FILTER, "$NfConf::PREFIX/nfdump -Z '$filterstr' 2>&1 |") ) {
		push @out, "Can't run nfdump for filter check: $!";
    $res{'nfdump'} = @out;
    $res{'exit'} = $?;
	} else {
		while ( <FILTER> ) {
			push @out, $_;
		}
    $res{'nfdump'} = @out;
    $res{'exit'} = $?;
		close FILTER;
	}

	return %res;

} # End of VerifyFilter

# Query user for yes or no
sub UserInput {
	my $text = shift;

	my $answer = '';
	while ( $answer !~ /^[y|n]$/ ) {
		print "$text [y/n] ";
		$answer = <STDIN>;
		$answer =~ s/^yes$/y/i;
		$answer =~ s/^no$/n/i;
		chomp $answer;
	}
	return $answer;
} # End of UserInput

sub GetFrontendPlugins {
	my $socket  = shift;
	my $opts	= shift;

	foreach my $entry ( @NfConf::plugins ) {
		my $plugin	  = $$entry[1];
		if ( -f "$NfConf::FRONTEND_PLUGINDIR/${plugin}.php" ) {
			print $socket "_frontendplugins=$plugin\n";
		}
	}

	print $EODATA;
	if ( defined $Log::ERROR ) {
		print $socket "ERR $Log::ERROR\n";
	} else {
		print $socket "OK Listing complete\n";
	}

	return;

} # End of GetFrontendPlugins

sub CleanOrphans {

	foreach my $profilegroup ( NfProfile::ProfileGroups() ) {
		my @AllProfiles = NfProfile::ProfileList($profilegroup);
		if ( scalar @AllProfiles == 0 ) {
			syslog('err', $Log::ERROR) if defined $Log::ERROR;
			return;
		}
		foreach my $profilename ( NfProfile::ProfileList($profilegroup) ) {
			my $orphan_name;
			if ( ($profilegroup eq '.' && $profilename eq 'live' ) ) {
				$orphan_name = 'nfcapd.current';
			} else {
				$orphan_name = 'nfprofile';
			}
			my %profileinfo = NfProfile::ReadProfile($profilename, $profilegroup);

			my $profilepath = NfProfile::ProfilePath($profilename, $profilegroup);
			foreach my $channel ( keys %{$profileinfo{'channel'}} ) {
				my $channeldir = "$NfConf::PROFILEDATADIR/$profilepath/$channel";

				if ( !opendir(DIR, $channeldir) ) {
					syslog('err', "Can't open channel directory '$channeldir': $!");
					next;
				}
				my @orphans = grep { -f "$channeldir/$_" && /$orphan_name\.\d+/ } readdir(DIR);
				closedir DIR;
				foreach my $file ( @orphans ) {
					syslog('err', "Clean orphan data file: '$channeldir/$file'");
					unlink "$channeldir/$file";
				}
			}
		}
	}

} # End of CleanOrphans

sub GetDefaultFilterList {
	my $socket  = shift;
	my $opts	= shift;

    opendir(FILTERS, "$NfConf::FILTERDIR" ) or
		print $socket $EODATA,
        print "ERR Can't open filter directory '$NfConf::FILTERDIR': $!", 
        return;

    my @AllFilters = grep { $_ !~ /^\.+/ && -f "$NfConf::FILTERDIR/$_" } readdir(FILTERS);

    closedir FILTERS;

	foreach my $filter ( @AllFilters ) {
		print $socket "_list=$filter\n";
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of GetDefaultFilterList


sub GetDefaultFilter {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'filter'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing filter name!\n";
		return;
	}
	my $name = $$opts{'filter'};
	if ( $name =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in filter name '$name': '$&'!\n";
		return;
	}

	if ( !-f "$NfConf::FILTERDIR/$name" ) {
		print $socket $EODATA;
		print $socket "ERR filter '$name' No such filter!\n";
		return;
	}

	if ( open FILTER, "$NfConf::FILTERDIR/$name" ) {
		while ( <FILTER> ) {
			chomp;
			print $socket "_filter=$_\n";
		}
		close FILTER;
	} else {
		print $socket $EODATA;
		print $socket "ERR filter '$name': $!!\n";
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of GetDefaultFilter

sub AddDefaultFilter {
	my $socket  = shift;
	my $opts	= shift;

	
	if ( !exists $$opts{'filtername'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing filter name!\n";
		return;
	}
	my $name = $$opts{'filtername'};
	if ( $name =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in filter name '$name': '$&'!\n";
		return;
	}

	if ( -f "$NfConf::FILTERDIR/$name" && !exists $$opts{'overwrite'} ) {
		print $socket $EODATA;
		print $socket "ERR filter '$name' already exists!\n";
		return;
	}

	if ( !exists $$opts{'filter'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing filter!\n";
		return;
	}

	my $filter = $$opts{'filter'};

	my %out = VerifyFilter($filter);
	if ( $out{'exit'} > 0 ) {
		print $socket $EODATA;
		print $socket "ERR Filter syntax error: ", join(' ', $out{'nfdump'}), "\n";
		return;
	}

	# clean old file
	unlink "$NfConf::FILTERDIR/$name";
	if ( !open FILTER, ">$NfConf::FILTERDIR/$name" ) {
		print $socket $EODATA;
		print $socket "ERR Failed to open filter file '$name': $!!\n";
		return;
	}
	print FILTER join "\n", @$filter;
	close FILTER;

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of AddDefaultFilter

sub DeleteDefaultFilter {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'filtername'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing filter name!\n";
		return;
	}
	my $name = $$opts{'filtername'};
	if ( $name =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in filter name '$name': '$&'!\n";
		return;
	}

	if ( ! -f "$NfConf::FILTERDIR/$name" ) {
		print $socket $EODATA;
		print $socket "ERR No such filter '$name'!\n";
		return;
	}

	if ( !unlink "$NfConf::FILTERDIR/$name" ) {
		print $socket $EODATA;
		print $socket "ERR Can not delete filter '$name': $!!\n";
		return;
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of DeleteDefaultFilter


sub GetOutputFormats {
	my $socket  = shift;
	my $opts	= shift;

    opendir(FORMATS, "$NfConf::FORMATDIR" ) or
		print $socket $EODATA,
        print "ERR Can't open format directory '$NfConf::FORMATDIR' : $!", 
        return;

    my @AllFormats = grep { $_ !~ /^\.+/ && -f "$NfConf::FORMATDIR/$_" } readdir(FORMATS);

    closedir FORMATS;

	foreach my $format ( @AllFormats ) {
		if ( open FMT, "$NfConf::FORMATDIR/$format" ) {
			my $formatdef = <FMT>;
			close FMT;
			chomp $formatdef;
			print $socket "$format=$formatdef\n";
		} else {
			print STDERR "Format file read error: $!\n";
		}
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of GetOutputFormats

sub AddOuputFormat {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'format'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing format!\n";
		return;
	}

	my $format = $$opts{'format'};
	if ( $format =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in format name '$format': '$&'!\n";
		return;
	}

	if ( $format eq 'line' || $format eq 'long' || $format eq 'extended' ) {
		print $socket $EODATA;
		print $socket "ERR format name '$format' is a predefined format!\n";
		return;
	}

	if ( !exists $$opts{'formatdef'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing format definition!\n";
		return;
	}
	my $formatdef = $$opts{'formatdef'};
	if ( $formatdef =~ /[^\s!-~]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in format definition '$formatdef'!\n";
		return;
	}

	if ( -f "$NfConf::FORMATDIR/$format" && !exists $$opts{'overwrite'} ) {
		print $socket $EODATA;
		print $socket "ERR format '$format' already exists!\n";
		return;
	}

	# clean old file
	unlink "$NfConf::FORMATDIR/$format";
	if ( !open FMT, ">$NfConf::FORMATDIR/$format" ) {
		print $socket $EODATA;
		print $socket "ERR Failed to open format file '$format': $!!\n";
		return;
	}
	print FMT "$formatdef\n";
	close FMT;

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of AddOuputFormat

sub DeleteOuputFormat {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'format'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing format!\n";
		return;
	}

	my $format = $$opts{'format'};
	if ( $format =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in format name '$format'!\n";
		return;
	}

	if ( ! -f "$NfConf::FORMATDIR/$format" ) {
		print $socket $EODATA;
		print $socket "ERR No such format '$format'!\n";
		return;
	}

	if ( !unlink "$NfConf::FORMATDIR/$format" ) {
		print $socket $EODATA;
		print $socket "ERR Can not delete format '$format': $!!\n";
		return;
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of DeleteOuputFormat

sub DiskUsage {
	my $socket 	= shift;
	my $opts 	= shift;

	my $df = '/bin/df -k ';
	print $socket ".Limit: $NfConf::DISKLIMIT on $NfConf::PROFILEDATADIR\n";
	if ( $NfConf::DISKLIMIT > 0 ) {

		open DF, "$df $NfConf::PROFILEDATADIR |" || 
			print $EODATA,
			print $socket "ERR Execute df: $!\n", return;

		my $last_df = 0;
		while ( <DF> ) {
			print $socket ".du line: $_";
			if ( /(\d+)%/ ) {
				$last_df = $1;
			} 
		}
		if ( $last_df > $NfConf::DISKLIMIT ) {
			print $socket $EODATA;
			print $socket "ALERT Your PROFILEDATADIR $NfConf::PROFILEDATADIR is $last_df% full!\n";
		} else {
			print $socket $EODATA;
			print $socket "OK command completed\n";
		}
	} else {
		print $socket $EODATA;
		print $socket "OK command completed\n";
	}

} # End of DiskUsage

sub SendAnyPicture {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'picture'} ) {
		print $socket $EODATA;
		print $socket "ERR picture required.\n";
		return;
	}
	my $picture = $$opts{'picture'};
	if ( $picture =~ /\.\./ ) {
		print $socket $EODATA;
		print $socket "ERR invalid picture path.\n";
		return;
	}

	if ( ! -f "$NfConf::PICDIR/$picture" ) {
		print $socket $EODATA;
		print $socket "ERR picture does not exists.\n";
		return;
	}

	sysopen(PIC, "$NfConf::PICDIR/$picture", O_RDONLY) or
		print $socket $EODATA,
		print $socket "ERR Can't open picture file: $!",
		return;

	my $buf;
	while ( sysread(PIC, $buf, 1024)) {
		syswrite($socket, $buf, length($buf));
	}
	close PIC;

} # End of SendAnyPicture

sub LoadHints {

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		$hints = lock_retrieve "$NfConf::PROFILESTATDIR/hints";
	};

	if ( my $err = $@ ) {
		syslog('err', "Error reading hints: $err\n");
		syslog('err', "Initialize hints to defaults.\n");
		$$hints{'version'} 	 	= -1;	# unknown
		$$hints{'installed'} 	= 0;
		$$hints{'subdirlayout'} = $NfConf::SUBDIRLAYOUT;
	}

	return \$hints;

} # End of LoadHints

sub StoreHints {

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		lock_store $hints, "$NfConf::PROFILESTATDIR/hints";
	};

	if ( my $err = $@ ) {
		syslog('err', "Error store hints: $err\n");
		return $err;
	}

} # End of StoreAlertStatus

1;
