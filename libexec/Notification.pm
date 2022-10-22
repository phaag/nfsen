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
#  $Id: Notification.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

package Notification;

use strict;

# What we import
use Sys::Syslog;

use Mail::Header;
use Mail::Internet;

# What we export

use vars qw(@ISA @EXPORT);
use Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(notify);

#
# notify:
#	input:		Subject of the Mail
#	body_ref:	Reference to the mail body
#		Example: notify('Notification email', \@BodyText);
#
sub notify {
	my $subject   = shift;
	my $body_ref  = shift;
	my $rcpt_to = $NfConf::RCPT_TO ;
	if ( scalar @_ == 1 ) {
		$rcpt_to = shift;
	}

	syslog('debug', "notify: $subject");

	my @mail_head = ( 	
		"From: $NfConf::MAIL_FROM",
		"To: $rcpt_to",
		"Subject: $subject" 
	);

	my $mail_header = new Mail::Header( \@mail_head ) ;

	my $mail = new Mail::Internet( 
		Header => $mail_header, 
		Body   => $body_ref 
	);

	my @sent_to = $mail->smtpsend( 
		Host     => $NfConf::SMTP_SERVER , 
		Hello    => $NfConf::SMTP_SERVER, 
		MailFrom => $NfConf::MAIL_FROM 
	);

	# Do we have failed receipients?
	# build the difference between array @$NfConf::RCPT_TO and @sent_to
	my %_tmp;
	my @_recv = split /\*s,\*s/, $rcpt_to;
	@_tmp{@_recv} = 1;
	delete @_tmp{@sent_to};
	my @Failed = keys %_tmp;

	if ( scalar @Failed > 0 ) {
		foreach my $rcpt ( @Failed ) {
			syslog('err', "notify: Failed to send notification to: $rcpt");
		}
	} else {
		syslog('info', "notify: Successful sent mail: '$subject'");
	}
	
}

1;
