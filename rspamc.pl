#!/usr/bin/perl -w

# Simple script that read message from STDIN and test it on rspamd server
# using specified command.
#
# Usage: rspamc.pl [-c conf_file] [command] [-s statfile]
#
# By default rspamc.pl would read ./rspamd.conf and default command is SYMBOLS

use Socket qw(:DEFAULT :crlf);

my %cfg = (
    'conf_file' => './rspamd.conf',
    'command'   => 'SYMBOLS',
    'host'      => 'localhost',
    'port'      => '11333',
    'is_unix'   =>  0,
    'password'  =>  '',
    'control'   =>  0,
    'statfile'  =>  '',
);


sub usage {
    return "Usage: rspamc.pl [-c conf_file] [-s statfile] [command]";
}

# Load rspamd config params
sub parse_config {
    my ($is_ctrl) = @_;

    open CONF, "< $cfg{'conf_file'}" or die "config file $cfg{'conf_file'} cannot be opened";

    my $ctrl = 0;
    while (<CONF>) {
        if ($_ =~ /control\s*{/i) {
            $ctrl = 1;
        }
        if ($ctrl && $_ =~ /}/) {
            $ctrl = 0;
        }
        if (((!$is_ctrl && !$ctrl) || ($ctrl && $is_ctrl))
                && $_ =~ /^\s*bind_socket\s*=\s*((([^:]+):(\d+))|(\/\S*))/i) {
            if ($3 && $4) {
                $cfg{'host'} = $3;
                $cfg{'port'} = $4;
                $cfg{'is_unix'} = 0;
            }
            else {
                $cfg{'host'} = $5;
                $cfg{'is_unix'} = 1;
            }
        }
        if ($ctrl && $is_ctrl && $_ =~ /^\s*password\s*=\s*"(\S+)"/) {
            $cfg{'password'} = $1;
        }
    }

    close CONF;

}

sub connect_socket {
    my $sock;

    if ($cfg{'is_unix'}) {
        socket ($sock, PF_UNIX, SOCK_STREAM, 0) or die "cannot create unix socket";
        my $sun = sockaddr_un($cfg{'host'});
        connect ($sock, $sun) or die "cannot connect to socket $cfg{'host'}";
    }
    else {
        my $proto = getprotobyname('tcp');
        my $sin;
        socket ($sock, PF_INET, SOCK_STREAM, $proto) or die "cannot create tcp socket";
        if (inet_aton ($cfg{'host'})) {
            $sin = sockaddr_in ($cfg{'port'}, inet_aton($cfg{'host'}));
        }
        else {
            my $addr = gethostbyname($cfg{'host'});
            if (!$addr) {
                die "cannot resolve $cfg{'host'}";
            }
            $sin = sockaddr_in ($cfg{'port'}, $addr);
        }
        
        connect ($sock, $sin) or die "cannot connect to socket $cfg{'host'}:$cfg{'port'}";
    }
    return $sock;
}

# Currently just read stdin for user's message and pass it to rspamd
sub do_rspamc_command {
    my ($sock) = @_;

    my $input;
    while (defined (my $line = <>)) {
        $input .= $line;
    }

    print "Sending ". length ($input) ." bytes...\n";

    syswrite $sock, "$cfg{'command'} RSPAMC/1.0 $CRLF";
    syswrite $sock, "Content-Length: " . length ($input) . $CRLF . $CRLF;
    syswrite $sock, $input;
    syswrite $sock, $CRLF;
    while (<$sock>) {
        print $_;
    }
}

sub do_ctrl_auth {
    my ($sock) = @_;

    syswrite $sock, "password $cfg{'password'}" . $CRLF;
    if (defined (my $reply = <$sock>)) {
        my $end = <$sock>;
        if ($reply =~ /^password accepted/) {
            return 1;
        }
    }

    return 0;
}

sub do_control_command {
    my ($sock) = @_;

    # Read greeting first
    if (defined (my $greeting = <$sock>)) {
        if ($greeting !~ /^Rspamd version/) {
            die "not rspamd greeting line $greeting";
        }
    }
    if ($cfg{'command'} =~ /^learn$/i) {
        my $input;
        die "statfile is not specified to learn command" if !$cfg{'statfile'};

        while (defined (my $line = <>)) {
            $input .= $line;
        }
        
        if (do_ctrl_auth ($sock)) {
            my $len = length ($input);
            print "Sending $len bytes...\n";
            syswrite $sock, "learn $cfg{'statfile'} $len" . $CRLF;
            syswrite $sock, $input . $CRLF;
            if (defined (my $reply = <$sock>)) {
                if ($reply =~ /^learn ok/) {
                    print "Learn succeed\n";
                }
                else {
                    print "Learn failed\n";
                }
            }
        }
        else {
            print "Authentication failed\n";
        }
    }
    elsif ($cfg{'command'} =~ /(reload|shutdown)/i) {
        if (do_ctrl_auth ($sock)) {
            syswrite $sock, $cfg{'command'} . $CRLF;
            while (defined (my $line = <$sock>)) {
                last if $line =~ /^END/;
                print $line;
            }
        }
        else {
            print "Authentication failed\n";
        }
    }
    else {
        syswrite $sock, $cfg{'command'} . $CRLF;
        while (defined (my $line = <$sock>)) {
            last if $line =~ /^END/;
            print $line;
        }
    }
}

while (my $param = shift) {
    if ($param eq '-c') {
        my $value = shift;
        if ($value) {
            if (-r $value) {
                $cfg{'conf_file'} = $value;
            }
            else {
                die "config file $value is not readable";
            }
        }
        else {
            die usage();
        }
    }
    elsif ($param eq '-s') {
        my $value = shift;
        if ($value) {
            $cfg{'statfile'} = $value;
        }
        else {
            die usage();
        }
    }
    elsif ($param =~ /(SYMBOLS|SCAN|PROCESS|CHECK|REPORT_IFSPAM|REPORT)/i) {
        $cfg{'command'} = $1;
        $cfg{'control'} = 0;
    }
    elsif ($param =~ /(STAT|LEARN|SHUTDOWN|RELOAD|UPTIME)/i) {
        $cfg{'command'} = $1;
        $cfg{'control'} = 1;
    }
    else {
        die usage();
    }
}

parse_config ($cfg{'control'});
my $sock = connect_socket ();

if ($cfg{'control'}) {
    do_control_command ($sock);
}
else {
    do_rspamc_command ($sock);
}

close ($sock);
