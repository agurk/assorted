#!/usr/bin/perl

use strict;
use warnings;

use WWW::Mechanize;

sub main
{
    my ($from, $to, $airline) = @_;
    $airline = 'BA' unless ($airline);
    my $agent = WWW::Mechanize->new();
    $agent->get("https://www.britishairways.com/travel/flight-calculator") or die "Can't load page\n";

    $agent->submit_form(
        form_name => 'calculateMilesAndPoints',
        fields    => {  departureAirport => $from,
                        arrivalAirport => $to,
                        marketingAirline => $airline },
);

    my $count=0;
    my $fc = 'Class (fare code)';
    my $avios = 'Avios';
    my $tp = 'TP';

    foreach my $res ($agent->content() =~ /<p class="mobile-clear flight-data"><span><strong>([^<]*)<\/strong><\/span><span class="flight-points">([^<]*)<\/span><\/p><p class="mobile-clear avios-data"><span class="text">([^<]*)<\/span><\/p><p class="mobile-clear tier-points-data"><span class="text">([^<]*)<\/span><\/p>/pg)
    {
        printf ("%-50s | %-8s | %-4s\n", $fc, $avios, $tp) if ($count % 4 == 0); 
        print ('-'x67,"\n") if ( $count == 0 );
        
        $fc = $res if ($count % 4 == 0);
        $fc .= $res if ($count % 4 == 1);
        $avios = $res if ($count % 4 == 2);
        $tp = $res if ($count % 4 == 3 );
        $count++;
    }
        printf ("%-50s | %-8s | %-4s\n", $fc, $avios, $tp) if ($count % 4 == 0); 
}

main($ARGV[0], $ARGV[1], $ARGV[2]);

