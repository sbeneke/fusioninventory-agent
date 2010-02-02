package Ocsinventory::Agent::Task::SNMPQuery;

$0 = "Tracker_agent";

###########################################
################ Read Args ################
###########################################

my $xmlexportlocal = 0;
my $argnodisplay = 0;
my $argnoprogressbar = 0;

###########################################
############### Load modules ##############
###########################################

# Debug
   use diagnostics;
   use Data::Dumper;

use strict;
use Config;
use Net::SNMP qw(:snmp);
use Compress::Zlib;
use LWP::UserAgent;
use HTTP::Request::Common;
use XML::Simple;
use FindBin qw($Bin);
use File::stat;
#use FileHandle;
if (! $Config{'useithreads'}) {
	print("1..0 # Skip: Perl not compiled with 'useithreads'\n");
	exit(0);
}else {
	use threads;
	use threads::shared;
   if ($argnodisplay == 0) {
      print "Threads version: $threads::VERSION\n";
   }
	if ($threads::VERSION > 1.32){
		threads->set_stack_size(20*8192);
		my $thread_version="new";
      print "Compiled with Thread\n";
	} else {
      if ($argnodisplay == 0) {
         print "Perl is compiled with old version of thread, this script is run in degraded mod and can crash often\n";
      }
		my $thread_version="old";
	}
}

$| = 1;

###########################################
######### Initial values of Agent #########
###########################################

my $agent_version = '2.0 Beta';
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$hour  = sprintf("%02d", $hour);
$min  = sprintf("%02d", $min);
$yday = sprintf("%04d", $yday);
my $PID = $yday.$hour.$min;
my $max_procs;
my $pm;
my $description;

###########################################
##### Include serials for discovery
###########################################

#require $Bin.'/inc/errors.pm';
#require $Bin.'/inc/device_serials.pm';
#require $Bin.'/inc/functions.pm';
#require $Bin.'/inc/communications_serveur.pm';
#require $Bin.'/inc/tracker_snmp.pm';
#require $Bin.'/inc/tracker_xml.pm';
#
## Manufacturer specifications
#require $Bin.'/inc/devices/3com.pm';
#require $Bin.'/inc/devices/alcatel.pm';
#require $Bin.'/inc/devices/cisco.pm';
#require $Bin.'/inc/devices/epson.pm';
#require $Bin.'/inc/devices/hp.pm';
#require $Bin.'/inc/devices/kyocera.pm';
#require $Bin.'/inc/devices/samsung.pm';
#require $Bin.'/inc/devices/wyse.pm';
#
#require $Bin.'/inc/tracker_discovery.pm';
#require $Bin.'/inc/tracker_query.pm';
#
#require $Bin.'/inc/tracker_pid.pm';
#
#pid_check_lock();

#######################################################
############# Begin to start NetDiscovery #############
#######################################################


use ExtUtils::Installed;
use Ocsinventory::Agent::Config;
use Ocsinventory::Logger;
use Ocsinventory::Agent::Storage;
use Ocsinventory::Agent::XML::Query::SimpleMessage;
use Ocsinventory::Agent::XML::Response::Prolog;
use Ocsinventory::Agent::Network;
use Ocsinventory::Agent::SNMP;

use Ocsinventory::Agent::AccountInfo;

sub main {
    my ( undef ) = @_;

    my $self = {};
    bless $self;

    my $storage = new Ocsinventory::Agent::Storage({
            target => {
                vardir => $ARGV[0],
            }
        });

    my $data = $storage->restore("Ocsinventory::Agent");
    $self->{data} = $data;
    my $myData = $self->{myData} = $storage->restore(__PACKAGE__);

    my $config = $self->{config} = $data->{config};
    my $target = $self->{'target'} = $data->{'target'};
    my $logger = $self->{logger} = new Ocsinventory::Logger ({
            config => $self->{config}
        });
    $self->{prologresp} = $data->{prologresp};
    
    my $continue = 0;
    foreach my $num (@{$self->{'prologresp'}->{'parsedcontent'}->{OPTION}}) {
      if (defined($num)) {
        if ($num->{NAME} eq "SNMPQUERY") {
            $continue = 1;
        }
      }
    }
    if ($continue eq "0") {
        $logger->debug("No SNMPQuery. Exiting...");
        exit(0);
    }

    if ($target->{'type'} ne 'server') {
        $logger->debug("No server. Exiting...");
        exit(0);
    }

    my $network = $self->{network} = new Ocsinventory::Agent::Network ({

            logger => $logger,
            config => $config,
            target => $target,

        });

   $self->StartThreads();

   exit(0);
}


sub StartThreads {
   my ($self, $params) = @_;

   my $num_files = 1;
   my $device;
   my @devicetype;
   my $num;
   my $log;
#print Dumper($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]);
	my $nb_threads_query = $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]->{THREADS_QUERY};
	my $nb_core_query = $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]->{CORE_QUERY};
print "**************************************\n";
print "* Threads query : ".$nb_threads_query."\n";
print "* Core query : ".$nb_core_query."\n";
print "**************************************\n";
   $devicetype[0] = "NETWORKING";
   $devicetype[1] = "PRINTER";

   # Send infos to server :
   my $xml_thread = {};
   $xml_thread->{QUERY} = "SNMPQUERY";
   $xml_thread->{DEVICEID} = $self->{config}->{deviceid};
   $xml_thread->{CONTENT}->{AGENT}->{START} = '1';
   $xml_thread->{CONTENT}->{AGENT}->{AGENTVERSION} = $self->{config}->{VERSION};
   $xml_thread->{CONTENT}->{PROCESSNUMBER} = $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]->{PID};
   $self->SendInformations($xml_thread);
   undef($xml_thread);


	#===================================
	# Threads et variables partagées
	#===================================
   my %TuerThread : shared;
	my %ArgumentsThread :shared;
   my $devicelist = {};
   my %devicelist2 : shared;
   my $modelslist = {};
   my $authlist = {};
	my @Thread;

	$ArgumentsThread{'id'} = &share([]);
	$ArgumentsThread{'log'} = &share([]);
	$ArgumentsThread{'Bin'} = &share([]);
	$ArgumentsThread{'PID'} = &share([]);

   # Dispatch devices to different core
   my @i;
   my $nbip = 0;
   my @countnb;
   my $core_counter = 0;

   for($core_counter = 0 ; $core_counter < $nb_core_query ; $core_counter++) {
      $countnb[$core_counter] = 0;
      $devicelist2{$core_counter} = &share({});
   }

   $core_counter = 0;
   if (defined($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE})) {
      if (ref($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}) eq "HASH"){
         #if (keys (%{$data->{DEVICE}}) eq "0") {
         for (@devicetype) {
            if ($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{TYPE} eq $_) {
               if (ref($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}) eq "HASH"){
                  if ($core_counter eq $nb_core_query) {
                     $core_counter = 0;
                  }
                  $devicelist->{$core_counter}->{$countnb[$core_counter]} = {
                                 ID             => $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{ID},
                                 IP             => $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{IP},
                                 TYPE           => $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{TYPE},
                                 AUTHSNMP_ID    => $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{AUTHSNMP_ID},
                                 MODELSNMP_ID   => $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{MODELSNMP_ID}
                              };
                  $devicelist2{$core_counter}{$countnb[$core_counter]} = $countnb[$core_counter];
                  $countnb[$core_counter]++;
                  $core_counter++;
               } else {
                  foreach $num (@{$self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}->{$_}}) {
                     if ($core_counter eq $nb_core_query) {
                        $core_counter = 0;
                     }
                     #### MODIFIER
                     $devicelist->{$core_counter}->{$countnb[$core_counter]} = $num;
                     $devicelist2{$core_counter}[$countnb[$core_counter]] = $countnb[$core_counter];
                     $countnb[$core_counter]++;
                     $core_counter++;
                  }
               }
            }
         }
      } else {
         foreach $device (@{$self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{DEVICE}}) {
            if (defined($device)) {
               if (ref($device) eq "HASH"){
                  if ($core_counter eq $nb_core_query) {
                     $core_counter = 0;
                  }
                  #### MODIFIER
                  $devicelist->{$core_counter}->{$countnb[$core_counter]} = {
                                 ID             => $device->{ID},
                                 IP             => $device->{IP},
                                 TYPE           => $device->{TYPE},
                                 AUTHSNMP_ID    => $device->{AUTHSNMP_ID},
                                 MODELSNMP_ID   => $device->{MODELSNMP_ID}
                              };
                  $devicelist2{$core_counter}{$countnb[$core_counter]} = $countnb[$core_counter];
                  $countnb[$core_counter]++;
                  $core_counter++;
               } else {
                  foreach $num (@{$device}) {
                     if ($core_counter eq $nb_core_query) {
                        $core_counter = 0;
                     }
                     #### MODIFIER
                     $devicelist->{$core_counter}->{$countnb[$core_counter]} = $num;
                     $devicelist2{$core_counter}[$countnb[$core_counter]] = $countnb[$core_counter];
                     $countnb[$core_counter]++;
                     $core_counter++;
                  }
               }
            }
         }
      }
   }

   # Models SNMP
   $modelslist = $self->ModelParser($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]);

   # Auth SNMP
   $authlist = $self->AuthParser($self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]);

   #============================================
	# Begin ForkManager (multiple core / process)
	#============================================
   $max_procs = $nb_core_query*$nb_threads_query;
   if ($nb_core_query > 1) {
      use Parallel::ForkManager;
      $pm=new Parallel::ForkManager($max_procs);
   }

   my $xml_Thread : shared = '';
   my %xml_out : shared;
   my $sendXML :shared = 0;
   for(my $p = 0; $p < $nb_core_query; $p++) {
      if ($nb_core_query > 1) {
   		my $pid = $pm->start and next;
      }
#      write_pid();
      # Création des threads
      $TuerThread{$p} = &share([]);

      for(my $j = 0 ; $j < $nb_threads_query ; $j++) {
         $TuerThread{$p}[$j]    = 0;					# 0 : thread en vie, 1 : thread se termine
      }
      #==================================
      # Prepare in variables devices to query
      #==================================
      $ArgumentsThread{'id'}[$p] = &share([]);
      $ArgumentsThread{'Bin'}[$p] = &share([]);
      $ArgumentsThread{'log'}[$p] = &share([]);
      $ArgumentsThread{'PID'}[$p] = &share([]);

      my $i = 0;

      while ($i < $nb_threads_query) {
         $ArgumentsThread{'Bin'}[$p][$i] = $Bin;
         $ArgumentsThread{'log'}[$p][$i] = $log;
         $ArgumentsThread{'PID'}[$p][$i] = $PID;
         $i++;
      }
      #===================================
      # Create all Threads
      #===================================
      for(my $j = 0; $j < $nb_threads_query; $j++) {
         $Thread[$p][$j] = threads->create( sub {
                                                   my $p = shift;
                                                   my $t = shift;
                                                   my $devicelist = shift;
                                                   my $modelslist = shift;
                                                   my $authlist = shift;
                                                   my $PID = shift;

                                                   my $device_id;
                                                   my $xml_thread = {};
                                                   my $count = 0;
                                                   my $xmlout;
                                                   my $xml;
                                                   my $data_compressed;

                                                   #$xml_thread->{CONTENT}->{AGENT}->{DEVICEID}; # Key
                                                   # PID ?
                                                   #

                                                   BOUCLET: while (1) {
                                                      #print "Thread\n";
                                                      # Lance la procédure et récupère le résultat
                                                      $device_id = "";

                                                      {
                                                         lock %devicelist2;
                                                         if (keys %{$devicelist2{$p}} ne "0") {
                                                            my @keys = sort keys %{$devicelist2{$p}};
                                                            $device_id = pop @keys;
                                                            delete $devicelist2{$p}{$device_id};
                                                         } else {
                                                            last BOUCLET;
                                                         }
                                                      }
                                                      #print Dumper($devicelist->{$device_id});
                                                      my $datadevice = query_device_threaded(
                                                         $devicelist->{$device_id},
                                                         $ArgumentsThread{'log'}[$p][$t],
                                                         $ArgumentsThread{'Bin'}[$p][$t],
                                                         $ArgumentsThread{'PID'}[$p][$t],
                                                         $agent_version,
                                                         $modelslist->{$devicelist->{$device_id}->{MODELSNMP_ID}}, # Passer uniquement le modèlle correspondant au device, ex : $modelslist->{'1'}
                                                         $authlist->{$devicelist->{$device_id}->{AUTHSNMP_ID}}
                                                         );
                                                      #undef $devicelist[$p]{$device_id};
                                                      $xml_thread->{CONTENT}->{DEVICE}->[$count] = $datadevice;
                                                      $xml_thread->{CONTENT}->{PROCESSNUMBER} = $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]->{PID};
                                                      $count++;
                                                      if ($count eq "4") { # Send all of 4 devices
                                                         $xml_thread->{QUERY} = "SNMPQUERY";
                                                         $self->SendInformations($xml_thread);
                                                         $TuerThread{$p}[$t] = 1;
                                                         $count = 0;
                                                      }
                                                   }
                                                   $xml_thread->{QUERY} = "SNMPQUERY";
                                                   $self->SendInformations($xml_thread);
                                                   $TuerThread{$p}[$t] = 1;
                                                   return;
                                                }, $p, $j, $devicelist->{$p},$modelslist,$authlist,$PID)->detach();
         sleep 1;
      }

      my $exit = 0;
      while($exit eq "0") {
         sleep 2;
         my $count = 0;
         for(my $i = 0 ; $i < $nb_threads_query ; $i++) {
            if ($TuerThread{$p}[$i] eq "1") {
               $count++;
            }
            if ( $count eq $nb_threads_query ) {
               $exit = 1;
            }
         }
      }

      if ($nb_core_query > 1) {
         $pm->finish;
      }
	}
   if ($nb_core_query > 1) {
   	$pm->wait_all_children;
   }

   # Send infos to server :
   undef($xml_thread);
   $xml_thread->{QUERY} = "SNMPQUERY";
   $xml_thread->{CONTENT}->{AGENT}->{END} = '1';
   $xml_thread->{CONTENT}->{PROCESSNUMBER} = $self->{'prologresp'}->{'parsedcontent'}->{OPTION}->[1]->{PARAM}->[0]->{PID};
   $self->SendInformations($xml_thread);
   undef($xml_thread);

}


sub SendInformations{
   my ($self, $message) = @_;

   my $config = $self->{config};
   my $target = $self->{'target'};
   my $logger = $self->{logger};

   my $network = $self->{network};

   if ($config->{stdout}) {
      $message->printXML();
   } elsif ($config->{local}) {
      $message->writeXML();
   } elsif ($config->{server}) {

      my $xmlout = new XML::Simple(
                           RootName => 'REQUEST',
                           NoAttr => 1,
                           KeyAttr => [],
                           suppressempty => 1
                        );
      my $xml = $xmlout->XMLout($message);
      if ($xml ne "") {
         my $data_compressed = Compress::Zlib::compress($xml);
         send_snmp_http2($data_compressed,$PID,$config->{'server'});
      }
   }
}

sub AuthParser {
   my ($self, $dataAuth) = @_;

   my $authlist = {};

   if (ref($dataAuth->{AUTHENTICATION}) eq "HASH"){
      $authlist->{$dataAuth->{AUTHENTICATION}->{ID}} = {
               COMMUNITY      => $dataAuth->{AUTHENTICATION}->{COMMUNITY},
               VERSION        => $dataAuth->{AUTHENTICATION}->{VERSION},
               USERNAME       => $dataAuth->{AUTHENTICATION}->{USERNAME},
               AUTHPASSWORD   => $dataAuth->{AUTHENTICATION}->{AUTHPASSPHRASE},
               AUTHPROTOCOL   => $dataAuth->{AUTHENTICATION}->{AUTHPROTOCOL},
               PRIVPASSWORD   => $dataAuth->{AUTHENTICATION}->{PRIVPASSPHRASE},
               PRIVPROTOCOL   => $dataAuth->{AUTHENTICATION}->{PRIVPROTOCOL}
            };
   } else {
      foreach my $num (@{$dataAuth->{AUTHENTICATION}}) {
         $authlist->{ $num->{ID} } = {
               COMMUNITY      => $num->{COMMUNITY},
               VERSION        => $num->{VERSION},
               USERNAME       => $num->{USERNAME},
               AUTHPASSWORD   => $num->{AUTHPASSPHRASE},
               AUTHPROTOCOL   => $num->{AUTHPROTOCOL},
               PRIVPASSWORD   => $num->{PRIVPASSPHRASE},
               PRIVPROTOCOL   => $num->{PRIVPROTOCOL}
            };
      }
   }
   return $authlist;
}


sub ModelParser {
   my $dataModel = shift;

   my $modelslist = {};
   my $lists;
   if (ref($dataModel->{MODEL}) eq "HASH"){
      foreach $lists (@{$dataModel->{MODEL}->{GET}}) {
         $modelslist->{$dataModel->{MODEL}->{ID}}->{GET}->{$lists->{LINK}} = {
                     OBJECT   => $lists->{OBJECT},
                     OID      => $lists->{OID},
                     VLAN     => $lists->{VLAN}
                  };
      }
      undef $lists;
      foreach $lists (@{$dataModel->{MODEL}->{WALK}}) {
         $modelslist->{$dataModel->{MODEL}->{ID}}->{WALK}->{$lists->{LINK}} = {
                     OBJECT   => $lists->{OBJECT},
                     OID      => $lists->{OID},
                     VLAN     => $lists->{VLAN}
                  };
      }
      undef $lists;
   } else {
      foreach my $num (@{$dataModel->{MODEL}}) {
         foreach $lists (@{$num->{GET}}) {
            $modelslist->{ $num->{ID} }->{GET}->{$lists->{LINK}} = {
                     OBJECT   => $lists->{OBJECT},
                     OID      => $lists->{OID},
                     VLAN     => $lists->{VLAN}
                  };
          }
         undef $lists;
         foreach $lists (@{$num->{WALK}}) {
            $modelslist->{ $num->{ID} }->{WALK}->{$lists->{LINK}} = {
                     OBJECT   => $lists->{OBJECT},
                     OID      => $lists->{OID},
                     VLAN     => $lists->{VLAN}
                  };
         }
         undef $lists;
      }
   }
   return $modelslist;
}



sub send_snmp_http {
	my $data_compressed = shift;
	my $PID = shift;
	my $config = shift;

 	my $url = $config;
	# Must send file and not by POST
	my $userAgent = LWP::UserAgent->new();
	my $response = $userAgent->post($url, [
	'upload' => '1',
	'data' => [ undef, $PID.'.xml.gz', Content => $data_compressed ],
	'md5_gzip' => '567894'],
	'content_type' => 'multipart/form-data');

	print $response->error_as_HTML . "\n" if $response->is_error;
   if ($response->content eq "Impossible to copy file in ../../../files/_plugins/tracker/") {
      ErrorCode('1002');
      delete_pid();
      exit;
   }
	#print $response->content."\n";
}

sub send_snmp_http2 {
	my $data_compressed = shift;
	my $PID = shift;
	my $config = shift;

   my $req = HTTP::Request->new(POST => $config);
   $req->header('Pragma' => 'no-cache', 'Content-type',
      'application/x-compress');

   $req->content($data_compressed);
   my $req2 = LWP::UserAgent->new(keep_alive => 1);
   my $res = $req2->request($req);

   # Checking if connected
   if(!$res->is_success) {
      print "PROBLEM\n";
      return;
   }
}



sub query_device_threaded {
	my $device = shift;
	my $log = shift;
	my $Bin = shift;
	my $PID = shift;
	my $agent_version = shift;
   my $modelslist = shift;
   my $authlist = shift;

# GESTION DES VLANS : CISCO
# .1.3.6.1.4.1.9.9.68.1.2.2.1.2 = vlan id
#
# vtpVlanName	.1.3.6.1.4.1.9.9.46.1.3.1.1.4.1
#

   my $ArraySNMPwalk = {};
   my $HashDataSNMP = {};
   my $datadevice = {};

	#threads->yield;

	############### SNMP Queries ###############
   my $session = new Ocsinventory::Agent::SNMP ({

               version      => $authlist->{VERSION},
               hostname     => $device->{IP},
               community    => $authlist->{COMMUNITY},
               username     => $authlist->{USERNAME},
               authpassword => $authlist->{AUTHPASSWORD},
               authprotocol => $authlist->{AUTHPROTOCOL},
               privpassword => $authlist->{PRIVPASSWORD},
               privprotocol => $authlist->{PRIVPROTOCOL},
               translate    => 1,

            });



	if (!defined($session->{SNMPSession}->{session})) {
		#debug($log,"[".$device->{IP}."] Error on connection","",$PID,$Bin);
		#print("SNMP ERROR: %s.\n", $error);
#      $datadevice->{ERROR}->{ID} = $device->{ID};
#      $datadevice->{ERROR}->{TYPE} = $device->{TYPE};
#      $datadevice->{ERROR}->{MESSAGE} = $error;
		return $datadevice;
	}
   my $session2 = new Ocsinventory::Agent::SNMP ({

               version      => $authlist->{VERSION},
               hostname     => $device->{IP},
               community    => $authlist->{COMMUNITY},
               username     => $authlist->{USERNAME},
               authpassword => $authlist->{AUTHPASSWORD},
               authprotocol => $authlist->{AUTHPROTOCOL},
               privpassword => $authlist->{PRIVPASSWORD},
               privprotocol => $authlist->{PRIVPROTOCOL},
               translate    => 0,

            });


	my $error = '';
	# Query for timeout #
	$description = snmpget('.1.3.6.1.2.1.1.1.0',1);
	my $insertXML = '';
	if ($description =~ m/No response from remote host/) {
		$error = "No response from remote host";
		#debug($log,"[".$device->{IP}."] $error","",$PID,$Bin);
      $datadevice->{ERROR}->{ID} = $device->{ID};
      $datadevice->{ERROR}->{TYPE} = $device->{TYPE};
      $datadevice->{ERROR}->{MESSAGE} = $error;
		return $datadevice;
	} else {
		# Query SNMP get #
      for my $key ( keys %{$modelslist->{GET}} ) {
         if ($modelslist->{GET}->{$key}->{VLAN} eq "0") {
            my $oid_result = $session->snmpget($modelslist->{GET}->{$key}->{OID});
            if (defined $oid_result
               && $oid_result ne ""
               && $oid_result ne "noSuchObject") {

               $HashDataSNMP->{$key} = $oid_result;
            }
         }
      }
      $datadevice->{INFO}->{ID} = $device->{ID};
      $datadevice->{INFO}->{TYPE} = $device->{TYPE};
      # Conversion
      ($datadevice, $HashDataSNMP) = ConstructDataDeviceSimple($HashDataSNMP,$datadevice);
#print Dumper($HashDataSNMP);
#      print "DATADEVICE GET ========================\n";
#print Dumper($datadevice);

      # Query SNMP walk #
      my $vlan_query = 0;
      for my $key ( keys %{$modelslist->{WALK}} ) {
         my $ArraySNMPwalk = {};
         $ArraySNMPwalk = $session->snmpwalk($modelslist->{WALK}->{$key}->{OID});
         $HashDataSNMP->{$key} = $ArraySNMPwalk;
         if ($modelslist->{WALK}->{$key}->{VLAN} eq "1") {
            $vlan_query = 1;
         }
      }
      # Conversion

      ($datadevice, $HashDataSNMP) = ConstructDataDeviceMultiple($HashDataSNMP,$datadevice);
#      print "DATADEVICE WALK ========================\n";

# print Dumper($datadevice);
# print Dumper($HashDataSNMP);

      if ($datadevice->{INFO}->{TYPE} eq "NETWORKING") {
         # Scan for each vlan (for specific switch manufacturer && model)
         # Implique de recréer une session spécialement pour chaque vlan : communauté@vlanID
         if ($vlan_query eq "1") {
            while ( (my $vlan_id,my $vlan_name) = each (%{$HashDataSNMP->{'vtpVlanName'}}) ) {
               for my $link ( keys %{$modelslist->{WALK}} ) {
                  if ($modelslist->{WALK}->{$link}->{VLAN} eq "1") {
                     $ArraySNMPwalk = {};
                     $ArraySNMPwalk = snmpwalk($modelslist->{WALK}->{$link}->{OID});
                     $HashDataSNMP->{VLAN}->{$vlan_id}->{$link} = $ArraySNMPwalk;
                  }
               }
               # Detect mac adress on each port
               if ($datadevice->{INFO}->{COMMENTS} =~ /Cisco/) {
                  ($datadevice, $HashDataSNMP) = Cisco_GetMAC($HashDataSNMP,$datadevice,$vlan_id);
               }
               delete $HashDataSNMP->{VLAN}->{$vlan_id};
            }
         } else {
            if ($datadevice->{INFO}->{COMMENTS} =~ /3Com IntelliJack/) {
               ($datadevice, $HashDataSNMP) = threecom_GetMAC($HashDataSNMP,$datadevice);
            }
         }
      }
      #print Dumper($datadevice);
      #print Dumper($HashDataSNMP);
	}
	#debug($log,"[".$device->{infos}->{ip}."] : end Thread", "",$PID,$Bin);
   return $datadevice;
}



sub special_char {
   if (defined($_[0])) {
      if ($_[0] =~ /0x$/) {
         return "";
      }
      $_[0] =~ s/([\x80-\xFF])//g;
      return $_[0];
   } else {
      return "";
   }
}



1;