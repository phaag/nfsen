#
#  Copyright (c) 2011, Peter Haag
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
#   * Neither the name of the author nor the names of its contributors may be
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
#  $Id: Log.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

package Log;

use strict;
use warnings;

use Sys::Syslog; 

use NfConf;

our $ERROR;

my $log_book = undef;

sub LogInit {

	Sys::Syslog::setlogsock($NfConf::LogSocket) if defined $NfConf::LogSocket;
	openlog("nfsen", 'cons,pid', $NfConf::syslog_facility);

} # End of LogInit

sub LogEnd {
	closelog();

} # End of LogEnd

sub StartLogBook {
	$log_book = shift;
} # End of SetLogBook

sub EndLogBook {
	$log_book = undef;
} # End of EndLogBook

sub TIEHANDLE {
	my $class	 = shift;
	my $name	 = shift;

	my %self;
	$self{'facility'} = $NfConf::syslog_facility;

	bless \%self, $class;

} # End of TIEHANDLE

sub PRINT {
	my $self = shift;
	my $msg = join '', @_;

	if ( defined $log_book ) {
		push @{$log_book}, $msg;
	}
	syslog('warning', "$msg"); 
}

sub UNTIE {
	my $self = shift;

} # End of UNTIE

1;
