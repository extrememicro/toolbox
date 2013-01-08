#!/usr/bin/perl -T
#
#  Author: Hari Sekhon
#  Date: 2011-05-24 10:38:54 +0100 (Tue, 24 May 2011)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

# Utility to watch a given URL and output it's status code. Useful for testing web farms and load balancers

$VERSION = "0.3";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils;
use LWP::UserAgent;
use POSIX;
use Time::HiRes qw/sleep time/;

# This is the max content length if on one line before outputting it on a separate line
my $default_output_length = 40;
my $output_length = $default_output_length;
my $count = 0;
my $output;
my $regex;
my $res;
my $returned = 0;
my $interval = 1;
my $status;
my $status_line;
my $time;
my $total = 0;
my $url;
my %stats;
my $time_taken;
my $tstamp1;
my $tstamp2;

$usage_line = "usage: $progname --url 'http://host/blah' --interval=1 --count=0 (unlimited)";

%options = (
    "u|url=s"           => [ \$url,           "URL to GET in http(s)://host/page.html form" ],
    "c|count=i"         => [ \$count,         "Number of times to request the given URL. Default: 0 (unlimited)" ],
    "i|interval=f"      => [ \$interval,      "Interval in secs between URL requests. Default: 1" ],
    "o|output"          => [ \$output,        "Show raw output at end of each line or on new line if output contains carriage returns or newlines or is longer than --output-length characters" ],
    "r|regex=s"         => [ \$regex,         "Output regex match of against entire web page (useful for testing embedded host information of systems behind load balancers)" ],
    "l|output-length=i" => [ \$output_length, "Max length of single line output before putting in on a separate line (defaults to $default_output_length chars)" ],
);
@usage_order=qw/url count interval output regex output-length/;

delete $HariSekhonUtils::default_options{"t|timeout=i"};

get_options();

#$url =~ /^(http:\/\/\w[\w\.-]+\w(?:\/[\w\.\;\=\&\%\/-]*)?)$/ or die "Invalid URL given\n";
$url = validate_url($url);
#isInt($count)      or usage "Invalid count given, must be a positive integer";
#isFloat($interval) or usage "Invalid sleep interval given, must be a positive floating point number";
#$interval > 0      or usage "Interval must be greater than zero";

#vlog_options "Count", $count ? $count : "$count (unlimited)";
validate_int($count, 0, "1000000", "count");
validate_float($interval, 0.00001, 1000, "interval");
$regex = validate_regex($regex) if $regex;
validate_int($output_length, 0, 1000, "output length");

my $ua = LWP::UserAgent->new;
$ua->agent("Hari Sekhon Watch URL version $main::VERSION ");
my $req = HTTP::Request->new(GET => $url);

print "="x133 . "\n";
#print "Time\t\t\tCount\t\tResult\t\tHTTP Status Code = Number (% of Total Requests, % of Returned Requests)\n";
print "Time\t\t\tCount\t\tResult\t\tRound Trip Time\t\tHTTP Status Code = % of Total Requests (number/total)\n";
print "="x133 . "\n";
#while(1){
for(my $i=1;$i<=$count or $count eq 0;$i++){
    $time = strftime("%F %T", localtime);
    vlog2 "* sending request";
    $tstamp1 = time;
    $res     = $ua->request($req);
    $tstamp2 = time;
    vlog2 "* got response";
    $status  = $status_line  = $res->status_line;
    $status  =~ s/\s.*$//;
    $total++;
    if($status !~ /^\d+$/){
        warn "$time\tCODE ERROR: status code '$status' is not a number (status line was: '$status_line')\n";
        next;
    }
    $returned += 1;
    $time_taken = sprintf("%.4f", $tstamp2 - $tstamp1);
    $msg = "$status_line\t\t$time_taken secs\t\t";
    $stats{$status} += 1;
    $returned = 0;
    foreach(keys %stats){
        $returned += $stats{$_};
    }
    foreach(sort keys %stats){
        #$msg .= "$_ = $stats{$_} (" . int($stats{$_} / $returned * 100) . "% $stats{$_}/$returned) (" . int($stats{$_} / $total * 100) . "% $stats{$_}/$total)\t\t";
        $msg .= "$_ = " . int($stats{$_} / $total * 100) . "% ($stats{$_}/$total)\t\t";
    }
    print "$time\t$i\t\t$msg";
    if($output or $regex or $verbose >= 3){
        my $content = $res->content;
        chomp $content;
        if($regex){
            $content =~ /($regex)/m;
            $content = $1 if $1;
        }
        if(length($content) > $output_length or $content =~ /[\r\n]/){
            print "\ncontent: $content\n";
        } else {
            print "content: $content";
        }
    }
    print "\n";
    vlog2 "* sleeping for $interval seconds\n";
    sleep $interval;
}
