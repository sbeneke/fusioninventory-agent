package FusionInventory::Agent::Task::Inventory::Input::Generic::Screen;

use strict;
use warnings;

use English qw(-no_match_vars);
use MIME::Base64;
use UNIVERSAL::require;

use File::Find;
use FusionInventory::Agent::Tools;

sub isEnabled {

    return
        $OSNAME eq 'MSWin32'                 ||
        -d '/sys'                            ||
        canRun('monitor-get-edid-using-vbe') ||
        canRun('monitor-get-edid')           ||
        canRun('get-edid');
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    foreach my $screen (_getScreens($logger)) {

        if ($screen->{edid}) {
            my $info = _getEdidInfo($screen->{edid}, $logger);
            $screen->{CAPTION}      = $info->{CAPTION};
            $screen->{DESCRIPTION}  = $info->{DESCRIPTION};
            $screen->{MANUFACTURER} = $info->{MANUFACTURER};
            $screen->{SERIAL}       = $info->{SERIAL};

            $screen->{BASE64} = encode_base64($screen->{edid});
            delete $screen->{edid};
        }

        $inventory->addEntry(
            section => 'MONITORS',
            entry   => $screen
        );
    }
}

sub _getEdidInfo {
    my ($raw_edid, $logger) = @_;

    Parse::EDID->require();
    return if $EVAL_ERROR;

    my $edid = Parse::EDID::parse_edid($raw_edid);
    if (my $error = Parse::EDID::check_parsed_edid($edid)) {
        $logger->debug("bad edid: $error");
        return;
    }

    my $info = {
        CAPTION      => $edid->{monitor_name},
        DESCRIPTION  => $edid->{week} . "/" . $edid->{year},
        MANUFACTURER => _getManufacturerFromCode($edid->{manufacturer_name}) ||
                        $edid->{manufacturer_name}
    };

    # they are two different serial numbers in EDID
    # - a mandatory 4 bytes numeric value
    # - an optional 13 bytes ASCII value
    # we use the ASCII value if present, the numeric value as an hex string
    # unless for a few list of known exceptions deserving specific handling
    # References:
    # http://forge.fusioninventory.org/issues/1607
    # http://forge.fusioninventory.org/issues/1614
    if (
        $edid->{EISA_ID} &&
        $edid->{EISA_ID} =~ /^ACR(0018|0020|0024|00A8|7883|ad49|adaf)$/
    ) {
        $info->{SERIAL} =
            substr($edid->{serial_number2}->[0], 0, 8) .
            sprintf("%08x", $edid->{serial_number})    .
            substr($edid->{serial_number2}->[0], 8, 4) ;
    } elsif (
        $edid->{EISA_ID} &&
        $edid->{EISA_ID} eq 'GSM4b21'
    ) {
        # split serial in two parts
        my ($high, $low) = $edid->{serial_number} =~ /(\d+) (\d\d\d)$/x;

        # translate the first part using a custom alphabet
        my @alphabet = split(//, "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ");
        my $base     = scalar @alphabet;

        $info->{SERIAL} =
            $alphabet[$high / $base] . $alphabet[$high % $base] .
            $low;
    } else {
        $info->{SERIAL} = $edid->{serial_number2} ?
            $edid->{serial_number2}->[0]           :
            sprintf("%08x", $edid->{serial_number});
    }

    return $info;
}

# the full list is available here (ISA_PNPID_List.xlsx)
# http://msdn.microsoft.com/en-us/windows/hardware/gg463195.aspx
#
#
#This list is based on:
#  - the list from Microsoft website
#  - the entries of our list unfound in Microsoft list
#  - a filter s/\ +$// to remove trailing white space in string
#
# Some code have been reverted to our initial string:
#  - "DO NOT USE - AUO" back to "AU Optronics"
#  - "DO NOT USE - LPL" back to "LG Philips"
#
# The rest of "DO NOT USE - " prefix string has been dropped.
sub _getManufacturerFromCode {
    my ($code) = @_;

    # to be able to loop 2 time in a row on DATA
    seek(DATA, 0, 0);

    foreach my $line (<DATA>) {
       next unless $line =~ /^$code __ (.*)$/;
       return $1;
   }

   return;
}

sub _getScreensFromWindows {
    my ($logger) = @_;

    FusionInventory::Agent::Tools::Win32->use();
    if ($EVAL_ERROR) {
        print
            "Failed to load FusionInventory::Agent::Tools::Win32: $EVAL_ERROR";
        return;
    }

    my @screens;

    # Vista and upper, able to get the second screen
    foreach my $object (getWmiObjects(
        moniker    => 'winmgmts:{impersonationLevel=impersonate,authenticationLevel=Pkt}!//./root/wmi',
        class      => 'WMIMonitorID',
        properties => [ qw/InstanceName/ ]
    )) {
        next unless $object->{InstanceName};

        $object->{InstanceName} =~ s/_\d+//;
        push @screens, {
            id => $object->{InstanceName}
        };
    }

    # The generic Win32_DesktopMonitor class, the second screen will be missing
    foreach my $object (getWmiObjects(
        class => 'Win32_DesktopMonitor',
        properties => [ qw/
            Caption MonitorManufacturer MonitorType PNPDeviceID Availability
        / ]
    )) {
        next unless $object->{Availability};
        next unless $object->{PNPDeviceID};
        next unless $object->{Availability} == 3;

        push @screens, {
            id           => $object->{PNPDeviceID},
            NAME         => $object->{Caption},
            TYPE         => $object->{MonitorType},
            MANUFACTURER => $object->{MonitorManufacturer},
            CAPTION      => $object->{Caption}
        };
    }

    foreach my $screen (@screens) {
        next unless $screen->{id};
        $screen->{edid} = getRegistryValue(
            path => "HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Enum/$screen->{id}/Device Parameters/EDID",
            logger => $logger
        ) || '';
        $screen->{edid} =~ s/^\s+$//;
        delete $screen->{id};
    }

    return @screens;
}

sub _getScreensFromUnix {

    my @screens;

    if (-d '/sys/devices') {
        my $wanted = sub {
            return unless $_ eq 'edid';
            return unless -s $File::Find::name;
            my $edid = getAllLines(file => $File::Find::name);
            push @screens, { edid => $edid } if $edid;
        };

        no warnings 'File::Find';
        File::Find::find($wanted, '/sys/devices');

        return @screens if @screens;
    }

    my $edid =
        getAllLines(command => 'monitor-get-edid-using-vbe') ||
        getAllLines(command => 'monitor-get-edid');
    push @screens, { edid => $edid };

    return @screens if @screens;

    foreach (1..5) { # Sometime get-edid return an empty string...
        $edid = getFirstLine(command => 'get-edid');
        if ($edid) {
            push @screens, { edid => $edid };
            last;
        }
    }

    return @screens;
}

sub _getScreens {
    my ($logger) = @_;

    return $OSNAME eq 'MSWin32' ?
        _getScreensFromWindows($logger) : _getScreensFromUnix($logger);
}

1;

__DATA__
AAA __ Avolites Ltd
AAE __ Anatek Electronics Inc.
AAT __ Ann Arbor Technologies
ABA __ ABBAHOME   INC.
ABC __ AboCom System Inc
ABD __ Allen Bradley Company
ABE __ Alcatel Bell
ABT __ Anchor Bay Technologies, Inc.
ABV __ Advanced Research Technology
ACA __ Ariel Corporation
ACB __ Aculab Ltd
ACC __ Accton Technology Corporation
ACD __ AWETA BV
ACE __ Actek Engineering Pty Ltd
ACG __ A&R Cambridge Ltd
ACH __ Archtek Telecom Corporation
ACI __ Ancor Communications Inc
ACK __ Acksys
ACL __ Apricot Computers
ACM __ Acroloop Motion Control Systems Inc
ACO __ Allion Computer Inc.
ACP __ Aspen Tech Inc
ACR __ Acer Technologies
ACS __ Altos Computer Systems
ACT __ Applied Creative Technology
ACU __ Acculogic
ACV __ ActivCard S.A
ADA __ Addi-Data GmbH
ADB __ Aldebbaron
ADC __ Acnhor Datacomm
ADD __ Advanced Peripheral Devices Inc
ADE __ Arithmos, Inc.
ADH __ Aerodata Holdings Ltd
ADI __ ADI Systems Inc
ADK __ Adtek System Science Company Ltd
ADL __ ASTRA Security Products Ltd
ADM __ Ad Lib MultiMedia Inc
ADN __ Analog & Digital Devices Tel. Inc
ADP __ Adaptec Inc
ADR __ Nasa Ames Research Center
ADS __ Analog Devices Inc
ADT __ Aved Display Technologies
ADV __ Advanced Micro Devices Inc
ADX __ Adax Inc
AEC __ Antex Electronics Corporation
AED __ Advanced Electronic Designs, Inc.
AEI __ Actiontec Electric Inc
AEJ __ Alpha Electronics Company
AEM __ ASEM S.p.A.
AEN __ Avencall
AEP __ Aetas Peripheral International
AET __ Aethra Telecomunicazioni S.r.l.
AFA __ Alfa Inc
AGC __ Beijing Aerospace Golden Card Electronic Engineering Co.,Ltd.
AGI __ Artish Graphics Inc
AGL __ Argolis
AGM __ Advan Int'l Corporation
AGT __ Agilent Technologies
AHC __ Advantech Co., Ltd.
AIC __ Arnos Insturments & Computer Systems
AIE __ Altmann Industrieelektronik
AII __ Amptron International Inc.
AIL __ Altos India Ltd
AIM __ AIMS Lab Inc
AIR __ Advanced Integ. Research Inc
AIS __ Alien Internet Services
AIW __ Aiwa Company Ltd
AIX __ ALTINEX, INC.
AJA __ AJA Video Systems, Inc.
AKB __ Akebia Ltd
AKE __ AKAMI Electric Co.,Ltd
AKI __ AKIA Corporation
AKL __ AMiT Ltd
AKM __ Asahi Kasei Microsystems Company Ltd
AKP __ Atom Komplex Prylad
AKY __ Askey Computer Corporation
ALA __ Alacron Inc
ALC __ Altec Corporation
ALD __ In4S Inc
ALG __ Realtek Semiconductor Corp.
ALH __ AL Systems
ALI __ Acer Labs
ALJ __ Altec Lansing
ALK __ Acrolink Inc
ALL __ Alliance Semiconductor Corporation
ALM __ Acutec Ltd.
ALN __ Alana Technologies
ALO __ Algolith Inc.
ALP __ Alps Electric Company Ltd
ALR __ Advanced Logic
ALS __ Texas Advanced optoelectronics Solutions, Inc
ALT __ Altra
ALV __ AlphaView LCD
ALX __ ALEXON Co.,Ltd.
AMA __ Asia Microelectronic Development Inc
AMB __ Ambient Technologies, Inc.
AMC __ Attachmate Corporation
AMD __ Amdek Corporation
AMI __ American Megatrends Inc
AML __ Anderson Multimedia Communications (HK) Limited
AMN __ Amimon LTD.
AMO __ Amino Technologies PLC and Amino Communications Limited
AMP __ AMP Inc
AMT __ AMT International Industry
AMW __ AMW
AMX __ AMX LLC
ANA __ Anakron
ANC __ Ancot
AND __ Adtran Inc
ANI __ Anigma Inc
ANK __ Anko Electronic Company Ltd
ANL __ Analogix Semiconductor, Inc
ANO __ Anorad Corporation
ANP __ Andrew Network Production
ANR __ ANR Ltd
ANS __ Ansel Communication Company
ANT __ Ace CAD Enterprise Company Ltd
ANX __ Acer Netxus Inc
AOA __ AOpen Inc.
AOC __ AOC International (USA) Ltd.
AOE __ Advanced Optics Electronics, Inc.
AOL __ America OnLine
AOT __ Alcatel
APC __ American Power Conversion
APD __ AppliAdata
APG __ Horner Electric Inc
API __ A Plus Info Corporation
APL __ Aplicom Oy
APM __ Applied Memory Tech
APN __ Appian Tech Inc
APP __ Apple Computer Inc
APR __ Aprilia s.p.a.
APS __ Autologic Inc
APT __ Audio Processing Technology  Ltd
APV __ A+V Link
APX __ AP Designs Ltd
ARC __ Alta Research Corporation
ARE __ ICET S.p.A.
ARG __ Argus Electronics Co., LTD
ARI __ Argosy Research Inc
ARK __ Ark Logic Inc
ARL __ Arlotto Comnet Inc
ARM __ Arima
ARO __ Poso International B.V.
ARS __ Arescom Inc
ART __ Corion Industrial Corporation
ASC __ Ascom Strategic Technology Unit
ASD __ USC Information Sciences Institute
ASE __ AseV Display Labs
ASI __ Ahead Systems
ASK __ Ask A/S
ASL __ AccuScene Corporation Ltd
ASN __ Asante Tech Inc
ASP __ ASP Microelectronics Ltd
AST __ AST Research Inc
ASU __ Asuscom Network Inc
ASX __ AudioScience
ASY __ Rockwell Collins / Airshow Systems
ATA __ Allied Telesyn International (Asia) Pte Ltd
ATC __ Ably-Tech Corporation
ATD __ Alpha Telecom Inc
ATE __ Innovate Ltd
ATH __ Athena Informatica S.R.L.
ATI __ Allied Telesis KK
ATK __ Allied Telesyn Int'l
ATL __ Arcus Technology Ltd
ATM __ ATM Ltd
ATN __ Athena Smartcard Solutions Ltd.
ATO __ ASTRO DESIGN, INC.
ATP __ Alpha-Top Corporation
ATT __ AT&T
ATV __ Office Depot, Inc.
ATX __ Athenix Corporation
AUI __ Alps Electric Inc
AUO __ AU Optronics
AUR __ Aureal Semiconductor
AUT __ Autotime Corporation
AVA __ Avaya Communication
AVC __ Auravision Corporation
AVD __ Avid Electronics Corporation
AVE __ Add Value Enterpises (Asia) Pte Ltd
AVI __ Nippon Avionics Co.,Ltd
AVL __ Avalue Technology Inc.
AVM __ AVM GmbH
AVO __ Avocent Corporation
AVR __ AVer Information Inc.
AVT __ Avtek (Electronics) Pty Ltd
AVV __ SBS Technologies (Canada), Inc. (was Avvida Systems, Inc.)
AWC __ Access Works Comm Inc
AWL __ Aironet Wireless Communications, Inc
AWS __ Wave Systems
AXB __ Adrienne Electronics Corporation
AXC __ AXIOMTEK CO., LTD.
AXE __ D-Link Systems Inc (used as 2nd pnpid)
AXI __ American Magnetics
AXL __ Axel
AXO __ Axonic Labs LLC
AXP __ American Express
AXT __ Axtend Technologies Inc
AXX __ Axxon Computer Corporation
AXY __ AXYZ Automation Services, Inc
AYD __ Aydin Displays
AYR __ Airlib, Inc
AZM __ AZ Middelheim - Radiotherapy
AZT __ Aztech Systems Ltd
BAC __ Biometric Access Corporation
BAN __ Banyan
BBB __ an-najah university
BBH __ B&Bh
BBL __ Brain Boxes Limited
BCC __ Beaver Computer Corporaton
BCD __ Barco GmbH
BCM __ Broadcom
BCQ __ Deutsche Telekom Berkom GmbH
BCS __ Booria CAD/CAM systems
BDO __ Brahler ICS
BDR __ Blonder Tongue Labs, Inc.
BDS __ Barco Display Systems
BEC __ Elektro Beckhoff GmbH
BEI __ Beckworth Enterprises Inc
BEK __ Beko Elektronik A.S.
BEL __ Beltronic Industrieelektronik GmbH
BEO __ Baug & Olufsen
BFE __ B.F. Engineering Corporation
BGB __ Barco Graphics N.V
BGT __ Budzetron Inc
BHZ __ BitHeadz, Inc.
BIC __ Big Island Communications
BII __ Boeckeler Instruments Inc
BIL __ Billion Electric Company Ltd
BIO __ BioLink Technologies International, Inc.
BLI __ Busicom
BLN __ BioLink Technologies
BLP __ Bloomberg L.P.
BMI __ Benson Medical Instruments Company
BML __ BIOMED Lab
BMM __ BMM
BMS __ BIOMEDISYS
BNE __ Bull AB
BNK __ Banksia Tech Pty Ltd
BNO __ Bang & Olufsen
BNQ __ BenQ Corporation
BNS __ Boulder Nonlinear Systems
BOB __ Rainy Orchard
BOE __ BOE
BOI __ NINGBO BOIGLE DIGITAL TECHNOLOGY CO.,LTD
BOS __ BOS
BPD __ Micro Solutions, Inc.
BPU __ Best Power
BRA __ Braemac Pty Ltd
BRC __ BARC
BRG __ Bridge Information Co., Ltd
BRI __ Boca Research Inc
BRM __ Braemar Inc
BRO __ BROTHER INDUSTRIES,LTD.
BSE __ Bose Corporation
BSL __ Biomedical Systems Laboratory
BSN __ BRIGHTSIGN, LLC
BST __ BodySound Technologies, Inc.
BTC __ Bit 3 Computer
BTE __ Brilliant Technology
BTF __ Bitfield Oy
BTI __ BusTech Inc
BTO __ BioTao Ltd
BUF __ Yasuhiko Shirai Melco Inc
BUG __ B.U.G., Inc.
BUJ __ ATI Tech Inc
BUL __ Bull
BUR __ Bernecker & Rainer Ind-Eletronik GmbH
BUS __ BusTek
BUT __ 21ST CENTURY ENTERTAINMENT
BWK __ Bitworks Inc.
BXE __ Buxco Electronics
BYD __ byd:sign corporation
CAA __ Castles Automation Co., Ltd
CAC __ CA & F Elettronica
CAI __ Canon Inc.
CAL __ Acon
CAM __ Cambridge Audio
CAN __ Carrera Computer Inc
CAR __ Cardinal Company Ltd
CAS __ CASIO COMPUTER CO.,LTD
CAT __ Consultancy in Advanced Technology
CAV __ Cavium Networks, Inc
CBI __ ComputerBoards Inc
CBR __ Cebra Tech A/S
CBT __ Cabletime Ltd
CBX __ Cybex Computer Products Corporation
CCC __ C-Cube Microsystems
CCI __ Cache
CCJ __ CONTEC CO.,LTD.
CCL __ CCL/ITRI
CCP __ Capetronic USA Inc
CDC __ Core Dynamics Corporation
CDD __ Convergent Data Devices
CDE __ Colin.de
CDG __ Christie Digital Systems Inc
CDI __ Concept Development Inc
CDK __ Cray Communications
CDN __ Codenoll Technical Corporation
CDP __ CalComp
CDS __ Computer Diagnostic Systems
CDT __ IBM Corporation
CDV __ Convergent Design Inc.
CEA __ Consumer Electronics Association
CEC __ Chicony Electronics Company Ltd
CED __ Cambridge Electronic Design Ltd
CEF __ Cefar Digital Vision
CEI __ Crestron Electronics, Inc.
CEM __ MEC Electronics GmbH
CEN __ Centurion Technologies P/L
CEP __ C-DAC
CER __ Ceronix
CET __ TEC CORPORATION
CFG __ Atlantis
CGA __ Chunghwa Picture Tubes, LTD
CGS __ Chyron Corp
CGT __ congatec AG
CHA __ Chase Research PLC
CHC __ Chic Technology Corp.
CHD __ ChangHong Electric Co.,Ltd
CHE __ Acer Inc
CHG __ Sichuan Changhong Electric CO, LTD.
CHI __ Chrontel Inc
CHL __ Chloride-R&D
CHM __ CHIC TECHNOLOGY CORP.
CHO __ Sichuang Changhong Corporation
CHP __ CH Products
CHS __ Agentur Chairos
CHT __ Chunghwa Picture Tubes,LTD.
CHY __ Cherry GmbH
CIC __ Comm. Intelligence Corporation
CII __ Cromack Industries Inc
CIL __ Citicom Infotech Private Limited
CIN __ Citron GmbH
CIS __ Cisco Systems Inc
CIT __ Citifax Limited
CKC __ The Concept Keyboard Company Ltd
CKJ __ Carina System Co., Ltd.
CLA __ Clarion Company Ltd
CLD __ COMMAT L.t.d.
CLE __ Classe Audio
CLG __ CoreLogic
CLI __ Cirrus Logic Inc
CLM __ CrystaLake Multimedia
CLO __ Clone Computers
CLT __ automated computer control systems
CLV __ Clevo Company
CLX __ CardLogix
CMC __ CMC Ltd
CMD __ Colorado MicroDisplay, Inc.
CMG __ Chenming Mold Ind. Corp.
CMI __ C-Media Electronics
CMM __ Comtime GmbH
CMN __ Chimei Innolux Corporation
CMO __ Chi Mei Optoelectronics corp.
CMR __ Cambridge Research Systems Ltd
CMS __ CompuMaster Srl
CMX __ Comex Electronics AB
CNC __ Alvedon Computers Ltd
CNE __ Cine-tal
CNI __ Connect Int'l A/S
CNN __ Canon Inc
CNT __ COINT Multimedia Systems
COB __ COBY Electronics Co., Ltd
COD __ CODAN Pty. Ltd.
COI __ Codec Inc.
COL __ Rockwell Collins, Inc.
COM __ Comtrol Corporation
CON __ Contec Company Ltd
COO __ coolux GmbH
COR __ Corollary Inc
COS __ CoStar Corporation
COT __ Core Technology Inc
COW __ Polycow Productions
COX __ Comrex
CPC __ Ciprico Inc
CPD __ CompuAdd
CPI __ Computer Peripherals Inc
CPL __ Compal Electronics Inc
CPM __ Capella Microsystems Inc.
CPQ __ Compaq Computer Company
CPT __ cPATH
CPX __ Powermatic Data Systems
CRC __ CONRAC GmbH
CRD __ Cardinal Technical Inc
CRE __ Creative Labs Inc
CRI __ Crio Inc.
CRL __ Creative Logic  
CRN __ Cornerstone Imaging
CRO __ Extraordinary Technologies PTY Limited
CRQ __ Cirque Corporation
CRS __ Crescendo Communication Inc
CRV __ Cerevo Inc.
CRX __ Cyrix Corporation
CSB __ Transtex SA
CSC __ Crystal Semiconductor
CSD __ Cresta Systems Inc
CSE __ Concept Solutions & Engineering
CSI __ Cabletron System Inc
CSM __ Cosmic Engineering Inc.
CSO __ California Institute of Technology
CSS __ CSS Laboratories
CST __ CSTI Inc
CTA __ CoSystems Inc
CTC __ CTC Communication Development Company Ltd
CTE __ Chunghwa Telecom Co., Ltd.
CTL __ Creative Technology Ltd
CTM __ Computerm Corporation
CTN __ Computone Products
CTP __ Computer Technology Corporation
CTS __ Comtec Systems Co., Ltd.
CTX __ Creatix Polymedia GmbH
CUB __ Cubix Corporation
CUK __ Calibre UK Ltd
CVA __ Covia Inc.
CVS __ Clarity Visual Systems
CWR __ Connectware Inc
CXT __ Conexant Systems
CYB __ CyberVision
CYC __ Cylink Corporation
CYD __ Cyclades Corporation
CYL __ Cyberlabs
CYT __ Cytechinfo Inc
CYV __ Cyviz AS
CYW __ Cyberware
CZE __ Carl Zeiss AG
DAC __ Digital Acoustics Corporation
DAE __ Digatron Industrie Elektronik GmbH
DAI __ DAIS SET Ltd.
DAK __ Daktronics
DAL __ Digital Audio Labs Inc
DAN __ Danelec Marine A/S
DAS __ DAVIS AS
DAT __ Datel Inc
DAU __ Daou Tech Inc
DAV __ Davicom Semiconductor Inc
DAW __ DA2 Technologies Inc
DAX __ Data Apex Ltd
DBD __ Diebold Inc.
DBI __ DigiBoard Inc
DBK __ Databook Inc
DBL __ Doble Engineering Company
DBN __ DB Networks Inc
DCA __ Digital Communications Association
DCC __ Dale Computer Corporation
DCD __ Datacast LLC
DCE __ dSPACE GmbH
DCI __ Concepts Inc
DCL __ Dynamic Controls Ltd
DCM __ DCM Data Products
DCO __ Dialogue Technology Corporation
DCR __ Decros Ltd
DCS __ Diamond Computer Systems Inc
DCT __ Dancall Telecom A/S
DCV __ Datatronics Technology Inc
DDA __ DA2 Technologies Corporation
DDD __ Danka Data Devices
DDE __ Datasat Digital Entertainment
DDI __ Data Display AG
DDS __ Barco, n.v.
DDT __ Datadesk Technologies Inc
DDV __ Delta Information Systems, Inc
DEC __ Digital Equipment Corporation
DEI __ Deico Electronics
DEL __ Dell Inc.
DEN __ Densitron Computers Ltd
DEX __ idex displays
DFI __ DFI
DFK __ SharkTec A/S
DFT __ DEI Holdings dba Definitive Technology
DGA __ Digiital Arts Inc
DGC __ Data General Corporation
DGI __ DIGI International
DGK __ DugoTech Co., LTD
DGP __ Digicorp European sales S.A.
DGS __ Diagsoft Inc
DGT __ The Dearborn Group
DHP __ DH Print
DHT __ Projectavision Inc
DIA __ Diadem
DIG __ Digicom S.p.A.
DII __ Dataq Instruments Inc
DIM __ dPict Imaging, Inc.
DIN __ Daintelecom Co., Ltd
DIS __ Diseda S.A.
DIT __ Dragon Information Technology
DJE __ Capstone Visua lProduct Development
DJP __ Maygay Machines, Ltd
DKY __ Datakey Inc
DLB __ Dolby Laboratories Inc.
DLC __ Diamond Lane Comm. Corporation
DLG __ Digital-Logic GmbH
DLK __ D-Link Systems Inc
DLL __ Dell Inc
DLT __ Digitelec Informatique Park Cadera
DMB __ Digicom Systems Inc
DMC __ Dune Microsystems Corporation
DMM __ Dimond Multimedia Systems Inc
DMP __ D&M Holdings Inc, Professional Business Company
DMS __ DOME imaging systems
DMT __ Distributed Management Task Force, Inc. (DMTF)
DMV __ NDS Ltd
DNA __ DNA Enterprises, Inc.
DNG __ Apache Micro Peripherals Inc
DNI __ Deterministic Networks Inc.
DNT __ Dr. Neuhous Telekommunikation GmbH
DNV __ DiCon
DOL __ Dolman Technologies Group Inc
DOM __ Dome Imaging Systems
DON __ DENON, Ltd.
DOT __ Dotronic Mikroelektronik GmbH
DPA __ DigiTalk Pro AV
DPC __ Delta Electronics Inc
DPI __ DocuPoint
DPL __ Digital Projection Limited
DPM __ ADPM Synthesis sas
DPS __ Digital Processing Systems
DPT __ DPT
DPX __ DpiX, Inc.
DQB __ Datacube Inc
DRB __ Dr. Bott KG
DRC __ Data Ray Corp.
DRD __ DIGITAL REFLECTION INC.
DRI __ Data Race Inc
DRS __ DRS Defense Solutions, LLC
DSD __ DS Multimedia Pte Ltd
DSI __ Digitan Systems Inc
DSM __ DSM Digital Services GmbH
DSP __ Domain Technology Inc
DTA __ DELTATEC
DTC __ DTC Tech Corporation
DTE __ Dimension Technologies, Inc.
DTI __ Diversified Technology, Inc.
DTL __ e-Net Inc
DTN __ Datang  Telephone Co
DTO __ Deutsche Thomson OHG
DTT __ Design & Test Technology, Inc.
DTX __ Data Translation
DUA __ Dosch & Amand GmbH & Company KG
DVD __ Dictaphone Corporation
DVL __ Devolo AG
DVS __ Digital Video System
DVT __ Data Video
DWE __ Daewoo Electronics Company Ltd
DXC __ Digipronix Control Systems
DXD __ DECIMATOR DESIGN PTY LTD
DXL __ Dextera Labs Inc
DXP __ Data Expert Corporation
DXS __ Signet
DYC __ Dycam Inc
DYM __ Dymo-CoStar Corporation
DYX __ Dynax Electronics (HK) Ltd
EAS __ Evans and Sutherland Computer
EBH __ Data Price Informatica
EBT __ HUALONG TECHNOLOGY CO., LTD
ECA __ Electro Cam Corp.
ECC __ ESSential Comm. Corporation
ECI __ Enciris Technologies
ECK __ Eugene Chukhlomin Sole Proprietorship, d.b.a.
ECL __ Excel Company Ltd
ECM __ E-Cmos Tech Corporation
ECO __ Echo Speech Corporation
ECS __ ELITEGROUP Computer Systems
ECT __ Enciris Technologies
EDC __ e.Digital Corporation
EDG __ Electronic-Design GmbH
EDI __ Edimax Tech. Company Ltd
EDM __ EDMI
EDT __ Emerging Display Technologies Corp
EEE __ ET&T Technology Company Ltd
EEH __ EEH Datalink GmbH
EEP __ E.E.P.D. GmbH
EES __ EE Solutions, Inc.
EGA __ Elgato Systems LLC
EGD __ EIZO GmbH Display Technologies
EGL __ Eagle Technology
EGN __ Egenera, Inc.
EGO __ Ergo Electronics
EHJ __ Epson Research
EHN __ Enhansoft
EIC __ Eicon Technology Corporation
EIZ __ EIZO
EKA __ MagTek Inc.
EKC __ Eastman Kodak Company
EKS __ EKSEN YAZILIM
ELA __ ELAD srl
ELC __ Electro Scientific Ind
ELE __ Elecom Company Ltd
ELG __ Elmeg GmbH Kommunikationstechnik
ELI __ Edsun Laboratories
ELL __ Electrosonic Ltd
ELM __ Elmic Systems Inc
ELO __ Tyco Electronics
ELS __ ELSA GmbH
ELT __ Element Labs, Inc.
ELX __ Elonex PLC
EMB __ Embedded computing inc ltd
EMC __ eMicro Corporation
EME __ EMiNE TECHNOLOGY COMPANY, LTD.
EMG __ EMG Consultants Inc
EMI __ Ex Machina Inc
EMK __ Emcore Corporation
EMO __ ELMO COMPANY, LIMITED
EMU __ Emulex Corporation
ENC __ Eizo Nanao Corporation
END __ ENIDAN Technologies Ltd
ENE __ ENE Technology Inc.
ENI __ Efficient Networks
ENS __ Ensoniq Corporation
ENT __ Enterprise Comm. & Computing Inc
EPC __ Empac
EPI __ Envision Peripherals, Inc
EPN __ EPiCON Inc.
EPS __ KEPS
EQP __ Equipe Electronics Ltd.
EQX __ Equinox Systems Inc
ERG __ Ergo System
ERI __ Ericsson Mobile Communications AB
ERN __ Ericsson, Inc.
ERP __ Euraplan GmbH
ERT __ Escort Insturments Corporation
ESA __ Elbit Systems of America
ESC __ Eden Sistemas de Computacao S/A
ESD __ Ensemble Designs, Inc
ESG __ ELCON Systemtechnik GmbH
ESI __ Extended Systems, Inc.
ESK __ ES&S
ESL __ Esterline Technologies
ESN __ eSATURNUS
ESS __ ESS Technology Inc
EST __ Embedded Solution Technology
ESY __ E-Systems Inc
ETC __ Everton Technology Company Ltd
ETD __ ELAN MICROELECTRONICS CORPORATION
ETH __ Etherboot Project
ETI __ Eclipse Tech Inc
ETK __ eTEK Labs Inc.
ETL __ Evertz Microsystems Ltd.
ETS __ Electronic Trade Solutions Ltd
ETT __ E-Tech Inc
EUT __ Ericsson Mobile Networks B.V.
EVI __ eviateg GmbH
EVX __ Everex
EXA __ Exabyte
EXC __ Excession Audio
EXI __ Exide Electronics
EXN __ RGB Systems, Inc. dba Extron Electronics
EXP __ Data Export Corporation
EXT __ Exatech Computadores & Servicos Ltda
EXX __ Exxact GmbH
EXY __ Exterity Ltd
EYE __ eyevis GmbH
EZE __ EzE Technologies
EZP __ Storm Technology
FAR __ Farallon Computing
FBI __ Interface Corporation
FCB __ Furukawa Electric Company Ltd
FCG __ First International Computer Ltd
FCM __ Funai Electric Company of Taiwan
FCS __ Focus Enhancements, Inc.
FDC __ Future Domain
FDT __ Fujitsu Display Technologies Corp.
FEC __ FURUNO ELECTRIC CO., LTD.
FEL __ Fellowes & Questec
FEN __ Fen Systems Ltd.
FER __ Ferranti Int'L
FFC __ FUJIFILM Corporation
FFI __ Fairfield Industries
FGD __ Lisa Draexlmaier GmbH
FGL __ Fujitsu General Limited.
FHL __ FHLP
FIC __ Formosa Industrial Computing Inc
FIL __ Forefront Int'l Ltd
FIN __ Finecom Co., Ltd.
FIR __ Chaplet Systems Inc
FIS __ FLY-IT Simulators
FIT __ Feature Integration Technology Inc.
FJC __ Fujitsu Takamisawa Component Limited
FJS __ Fujitsu Spain
FJT __ F.J. Tieman BV
FLE __ ADTI Media, Inc
FLI __ Faroudja Laboratories
FLY __ Butterfly Communications
FMA __ Fast Multimedia AG
FMC __ Ford Microelectronics Inc
FMI __ Fujitsu Microelect Inc
FML __ Fujitsu Microelect Ltd
FMZ __ Formoza-Altair
FNC __ Fanuc LTD
FNI __ Funai Electric Co., Ltd.
FOA __ FOR-A Company Limited
FOS __ Foss Tecator
FOX __ HON HAI PRECISON IND.CO.,LTD.
FPE __ Fujitsu Peripherals Ltd
FPS __ Deltec Corporation
FPX __ Cirel Systemes
FRC __ Force Computers
FRD __ Freedom Scientific BLV
FRE __ Forvus Research Inc
FRI __ Fibernet Research Inc
FRS __ South Mountain Technologies, LTD
FSC __ Future Systems Consulting KK
FSI __ Fore Systems Inc
FST __ Modesto PC Inc
FTC __ Futuretouch Corporation
FTE __ Frontline Test Equipment Inc.
FTG __ FTG Data Systems
FTI __ FastPoint Technologies, Inc.
FTL __ FUJITSU TEN LIMITED
FTN __ Fountain Technologies Inc
FTR __ Mediasonic
FTW __ MindTribe Product Engineering, Inc.
FUJ __ Fujitsu Ltd
FUN __ sisel muhendislik
FUS __ Fujitsu Siemens Computers GmbH
FVC __ First Virtual Corporation
FVX __ C-C-C Group Plc
FWA __ Attero Tech, LLC
FWR __ Flat Connections Inc
FXX __ Fuji Xerox
FZC __ Founder Group Shenzhen Co.
FZI __ FZI Forschungszentrum Informatik
GAG __ Gage Applied Sciences Inc
GAL __ Galil Motion Control
GAU __ Gaudi Co., Ltd.
GCC __ GCC Technologies Inc
GCI __ Gateway Comm. Inc
GCS __ Grey Cell Systems Ltd
GDC __ General Datacom
GDI __ G. Diehl ISDN GmbH
GDS __ GDS
GDT __ Vortex Computersysteme GmbH
GEF __ GE Fanuc Embedded Systems
GEH __ GE Intelligent Platforms - Huntsville
GEM __ Gem Plus
GEN __ Genesys ATE Inc
GEO __ GEO Sense
GER __ GERMANEERS GmbH
GES __ GES Singapore Pte Ltd
GET __ Getac Technology Corporation
GFM __ GFMesstechnik GmbH
GFN __ Gefen Inc.
GGL __ Google Inc.
GIC __ General Inst. Corporation
GIM __ Guillemont International
GIP __ GI Provision Ltd
GIS __ AT&T Global Info Solutions
GJN __ Grand Junction Networks
GLD __ Goldmund - Digital Audio SA
GLE __ AD electronics
GLM __ Genesys Logic
GLS __ Gadget Labs LLC
GMK __ GMK Electronic Design GmbH
GML __ General Information Systems
GMM __ GMM Research Inc
GMN __ GEMINI 2000 Ltd
GMX __ GMX Inc
GND __ Gennum Corporation
GNN __ GN Nettest Inc
GNZ __ Gunze Ltd
GRA __ Graphica Computer
GRE __ GOLD RAIN ENTERPRISES CORP.
GRH __ Granch Ltd
GRM __ Garmin International
GRV __ Advanced Gravis
GRY __ Robert Gray Company
GSB __ NIPPONDENCHI CO,.LTD
GSC __ General Standards Corporation
GSM __ Goldstar Company Ltd
GST __ Graphic SystemTechnology
GSY __ Grossenbacher Systeme AG
GTC __ Graphtec Corporation
GTI __ Goldtouch
GTK __ G-Tech Corporation
GTM __ Garnet System Company Ltd
GTS __ Geotest Marvin Test Systems Inc
GTT __ General Touch Technology Co., Ltd.
GUD __ Guntermann & Drunck GmbH
GUZ __ Guzik Technical Enterprises
GVC __ GVC Corporation
GVL __ Global Village Communication
GWI __ GW Instruments
GWY __ Gateway 2000
GZE __ GUNZE Limited
HAE __ Haider electronics
HAI __ Haivision Systems Inc.
HAL __ Halberthal
HAN __ Hanchang System Corporation
HAR __ Harris Corporation
HAY __ Hayes Microcomputer Products Inc
HCA __ DAT
HCE __ Hitachi Consumer Electronics Co., Ltd
HCL __ HCL America Inc
HCM __ HCL Peripherals
HCP __ Hitachi Computer Products Inc
HCW __ Hauppauge Computer Works Inc
HDC __ HardCom Elektronik & Datateknik
HDI __ HD-INFO d.o.o.
HDV __ Holografika kft.
HEC __ Hitachi Engineering Company Ltd
HEI __ Hyundai Electronics Industries Co., Ltd.
HEL __ Hitachi Micro Systems Europe Ltd
HER __ Ascom Business Systems
HET __ HETEC Datensysteme GmbH
HHC __ HIRAKAWA HEWTECH CORP.
HHI __ Fraunhofer Heinrich-Hertz-Institute
HIB __ Hibino Corporation
HIC __ Hitachi Information Technology Co., Ltd.
HIK __ Hikom Co., Ltd.
HIL __ Hilevel Technology
HIQ __ Kaohsiung Opto Electronics Americas, Inc.
HIT __ Hitachi America Ltd
HJI __ Harris & Jeffries Inc
HKA __ HONKO MFG. CO., LTD.
HKG __ Josef Heim KG
HMC __ Hualon Microelectric Corporation
HMK __ hmk Daten-System-Technik BmbH
HMX __ HUMAX Co., Ltd.
HNS __ Hughes Network Systems
HOB __ HOB Electronic GmbH
HOE __ Hosiden Corporation
HOL __ Holoeye Photonics AG
HON __ Sonitronix
HPA __ Zytor Communications
HPC __ Hewlett Packard Co.
HPD __ Hewlett Packard
HPI __ Headplay, Inc.
HPK __ HAMAMATSU PHOTONICS K.K.
HPQ __ HP
HPR __ H.P.R. Electronics GmbH
HRC __ Hercules
HRE __ Qingdao Haier Electronics Co., Ltd.
HRI __ Hall Research
HRL __ Herolab GmbH
HRS __ Harris Semiconductor
HRT __ HERCULES
HSC __ Hagiwara Sys-Com Company Ltd
HSD __ Hannspree Inc
HSL __ Hansol Electronics
HSP __ HannStar Display Corp
HTC __ Hitachi Ltd
HTI __ Hampshire Company, Inc.
HTK __ Holtek Microelectronics Inc
HTX __ Hitex Systementwicklung GmbH
HUB __ GAI-Tronics, A Hubbell Company
HUM __ IMP Electronics Ltd.
HWA __ Harris Canada Inc
HWC __ DBA Hans Wedemeyer
HWD __ Highwater Designs Ltd
HWP __ Hewlett Packard
HXM __ Hexium Ltd.
HYC __ Hypercope Gmbh Aachen
HYD __ Hydis Technologies.Co.,LTD
HYO __ HYC CO., LTD.
HYP __ Hyphen Ltd
HYR __ Hypertec Pty Ltd
HYT __ Heng Yu Technology (HK) Limited
HYV __ Hynix Semiconductor
IAF __ Institut f r angewandte Funksystemtechnik GmbH
IAI __ Integration Associates, Inc.
IAT __ IAT Germany GmbH
IBC __ Integrated Business Systems
IBI __ INBINE.CO.LTD
IBM __ IBM France
IBP __ IBP Instruments GmbH
IBR __ IBR GmbH
ICA __ ICA Inc
ICC __ BICC Data Networks Ltd
ICD __ ICD Inc
ICE __ IC Ensemble
ICI __ Infotek Communication Inc
ICL __ Fujitsu ICL
ICM __ Intracom SA
ICN __ Sanyo Icon
ICO __ Intel Corp
ICS __ Integrated Circuit Systems
ICV __ Inside Contactless
ICX __ ICCC A/S
IDC __ International Datacasting Corporation
IDE __ IDE Associates
IDK __ IDK Corporation
IDN __ Idneo Technologies
IDO __ IDEO Product Development
IDP __ Integrated Device Technology, Inc.
IDS __ Interdigital Sistemas de Informacao
IDT __ International Display Technology
IDX __ IDEXX Labs
IEC __ Interlace Engineering Corporation
IEE __ IEE
IEI __ Interlink Electronics
IFS __ In Focus Systems Inc
IFT __ Informtech
IFX __ Infineon Technologies AG
IFZ __ Infinite Z
IGC __ Intergate Pty Ltd
IGM __ IGM Communi
IHE __ InHand Electronics
IIC __ ISIC Innoscan Industrial Computers A/S
III __ Intelligent Instrumentation
IIN __ IINFRA Co., Ltd
IKS __ Ikos Systems Inc
ILC __ Image Logic Corporation
ILS __ Innotech Corporation
IMA __ Imagraph
IMB __ ART s.r.l.
IMC __ IMC Networks
IMD __ ImasDe Canarias S.A.
IMG __ IMAGENICS Co., Ltd.
IMI __ International Microsystems Inc
IMM __ Immersion Corporation
IMN __ Impossible Production
IMP __ Impression Products Incorporated
IMT __ Inmax Technology Corporation
INC __ Home Row Inc
IND __ ILC
INE __ Inventec Electronics (M) Sdn. Bhd.
INF __ Inframetrics Inc
ING __ Integraph Corporation
INI __ Initio Corporation
INK __ Indtek Co., Ltd.
INL __ InnoLux Display Corporation
INM __ InnoMedia Inc
INN __ Innovent Systems, Inc.
INO __ Innolab Pte Ltd
INS __ Ines GmbH
INT __ Interphase Corporation
INV __ Inviso, Inc.
IOA __ CRE Technology Corporation
IOD __ I-O Data Device Inc
IOM __ Iomega
ION __ Inside Out Networks
IOS __ i-O Display System
IOT __ I/OTech Inc
IPC __ IPC Corporation
IPD __ Industrial Products Design, Inc.
IPI __ Intelligent Platform Management Interface (IPMI) forum (Intel, HP, NEC, Dell)
IPM __ IPM Industria Politecnica Meridionale SpA
IPN __ Performance Technologies
IPP __ IP Power Technologies GmbH
IPR __ Ithaca Peripherals
IPS __ IPS, Inc. (Intellectual Property Solutions, Inc.)
IPT __ International Power Technologies
IPW __ IPWireless, Inc
IQI __ IneoQuest Technologies, Inc
IQT __ IMAGEQUEST Co., Ltd
IRD __ IRdata
ISA __ Symbol Technologies
ISC __ Id3 Semiconductors
ISG __ Insignia Solutions Inc
ISI __ Interface Solutions
ISL __ Isolation Systems
ISM __ Image Stream Medical
ISP __ IntreSource Systems Pte Ltd
ISR __ INSIS Co., LTD.
ISS __ ISS Inc
IST __ Intersolve Technologies
ISY __ International Integrated Systems,Inc.(IISI)
ITA __ Itausa Export North America
ITC __ Intercom Inc
ITD __ Internet Technology Corporation
ITK __ ITK Telekommunikation AG
ITL __ Inter-Tel
ITM __ ITM inc.
ITN __ The NTI Group
ITP __ IT-PRO Consulting und Systemhaus GmbH
ITR __ Infotronic America, Inc.
ITS __ IDTECH
ITT __ I&T Telecom.
ITX __ integrated Technology Express Inc
IUC __ ICSL
IVI __ Intervoice Inc
IVM __ Iiyama North America
IVS __ Intevac Photonics Inc.
IWR __ Icuiti Corporation
IWX __ Intelliworxx, Inc.
IXD __ Intertex Data AB
JAC __ Astec Inc
JAE __ Japan Aviation Electronics Industry, Limited
JAS __ Janz Automationssysteme AG
JAT __ Jaton Corporation
JAZ __ Carrera Computer Inc (used as second pnpid)
JCE __ Jace Tech Inc
JDL __ Japan Digital Laboratory Co.,Ltd.
JEN __ N-Vision
JET __ JET POWER TECHNOLOGY CO., LTD.
JFX __ Jones Futurex Inc
JGD __ University College
JIC __ Jaeik Information & Communication Co., Ltd.
JKC __ JVC KENWOOD Corporation
JMT __ Micro Technical Company Ltd
JPC __ JPC Technology Limited
JPW __ Wallis Hamilton Industries
JQE __ CNet Technical Inc
JSD __ JS DigiTech, Inc
JSI __ Jupiter Systems, Inc.
JSK __ SANKEN ELECTRIC CO., LTD
JTS __ JS Motorsports
JTY __ jetway security micro,inc
JUK __ Janich & Klass Computertechnik GmbH
JUP __ Jupiter Systems
JVC __ JVC
JWD __ Video International Inc.
JWL __ Jewell Instruments, LLC
JWS __ JWSpencer & Co.
JWY __ Jetway Information Co., Ltd
KAR __ Karna
KBI __ Kidboard Inc
KCD __ Chunichi Denshi Co.,LTD.
KCL __ Keycorp Ltd
KDE __ KDE
KDK __ Kodiak Tech
KDM __ Korea Data Systems Co., Ltd.
KDS __ KDS USA
KDT __ KDDI Technology Corporation
KEC __ Kyushu Electronics Systems Inc
KEM __ Kontron Embedded Modules GmbH
KES __ Kesa Corporation
KEY __ Key Tech Inc
KFC __ SCD Tech
KFX __ Kofax Image Products
KGL __ KEISOKU GIKEN Co.,Ltd.
KIS __ KiSS Technology A/S
KMC __ Mitsumi Company Ltd
KME __ KIMIN Electronics Co., Ltd.
KML __ Kensington Microware Ltd
KNC __ Konica corporation
KNX __ Nutech Marketing PTL
KOB __ Kobil Systems GmbH
KOE __ KOLTER ELECTRONIC
KOL __ Kollmorgen Motion Technologies Group
KOU __ KOUZIRO Co.,Ltd.
KOW __ KOWA Company,LTD.
KPC __ King Phoenix Company
KRL __ Krell Industries Inc.
KRM __ Kroma Telecom
KRY __ Kroy LLC
KSC __ Kinetic Systems Corporation
KSL __ Karn Solutions Ltd.
KSX __ King Tester Corporation
KTC __ Kingston Tech Corporation
KTD __ Takahata Electronics Co.,Ltd.
KTE __ K-Tech
KTG __ Kayser-Threde GmbH
KTI __ Konica Technical Inc
KTK __ Key Tronic Corporation
KTN __ Katron Tech Inc
KUR __ Kurta Corporation
KVA __ Kvaser AB
KVX __ KeyView
KWD __ Kenwood Corporation
KYC __ Kyocera Corporation
KYE __ KYE Syst Corporation
KYK __ Samsung Electronics America Inc
KZI __ K-Zone International co. Ltd.
KZN __ K-Zone International
LAB __ ACT Labs Ltd
LAC __ LaCie
LAF __ Microline
LAG __ Laguna Systems
LAN __ Sodeman Lancom Inc
LAS __ LASAT Comm. A/S
LAV __ Lava Computer MFG Inc
LBO __ Lubosoft
LCC __ LCI
LCD __ Toshiba Matsushita Display Technology Co., Ltd
LCE __ La Commande Electronique
LCI __ Lite-On Communication Inc
LCM __ Latitude Comm.
LCN __ LEXICON
LCS __ Longshine Electronics Company
LCT __ Labcal Technologies
LDT __ LogiDataTech Electronic GmbH
LEC __ Lectron Company Ltd
LED __ Long Engineering Design Inc
LEG __ Legerity, Inc
LEN __ Lenovo Group Limited
LEO __ First International Computer Inc
LEX __ Lexical Ltd
LGC __ Logic Ltd
LGD __ LG Display
LGI __ Logitech Inc
LGS __ LG Semicom Company Ltd
LGX __ Lasergraphics, Inc.
LHA __ Lars Haagh ApS
LHE __ Lung Hwa Electronics Company Ltd
LHT __ Lighthouse Technologies Limited
LIN __ Lenovo Beijing Co. Ltd.
LIP __ Linked IP GmbH
LIT __ Lithics Silicon Technology
LJX __ Datalogic Corporation
LKM __ Likom Technology Sdn. Bhd.
LLL __ L-3 Communications
LMG __ Lucent Technologies
LMI __ Lexmark Int'l Inc
LMP __ Leda Media Products
LMT __ Laser Master
LND __ Land Computer Company Ltd
LNK __ Link Tech Inc
LNR __ Linear Systems Ltd.
LNT __ LANETCO International
LNV __ Lenovo
LOC __ Locamation B.V.
LOE __ Loewe Opta GmbH
LOG __ Logicode Technology Inc
LOL __ Litelogic Operations Ltd
LPE __ El-PUSK Co., Ltd.
LPI __ Design Technology
LPL __ LG Philips
LSC __ LifeSize Communications
LSD __ Intersil Corporation
LSI __ Loughborough Sound Images
LSJ __ LSI Japan Company Ltd
LSL __ Logical Solutions
LSY __ LSI Systems Inc
LTC __ Labtec Inc
LTI __ Jongshine Tech Inc
LTK __ Lucidity Technology Company Ltd
LTN __ Litronic Inc
LTS __ LTS Scale LLC
LTV __ Leitch Technology International Inc.
LTW __ Lightware, Inc
LUM __ Lumagen, Inc.
LUX __ Luxxell Research Inc
LVI __ LVI Low Vision International AB
LWC __ Labway Corporation
LWR __ Lightware Visual Engineering
LWW __ Lanier Worldwide
LXC __ LXCO Technologies AG
LXN __ Luxeon
LXS __ ELEA CardWare
LZX __ Lightwell Company Ltd
MAC __ MAC System Company Ltd
MAD __ Xedia Corporation
MAE __ Maestro Pty Ltd
MAG __ MAG InnoVision
MAI __ Mutoh America Inc
MAL __ Meridian Audio Ltd
MAN __ LGIC
MAS __ Mass Inc.
MAT __ Matsushita Electric Ind. Company Ltd
MAX __ Rogen Tech Distribution Inc
MAY __ Maynard Electronics
MAZ __ MAZeT GmbH
MBC __ MBC
MBD __ Microbus PLC
MBM __ Marshall Electronics
MBV __ Moreton Bay
MCA __ American Nuclear Systems Inc
MCC __ Micro Industries
MCD __ McDATA Corporation
MCE __ Metz-Werke GmbH & Co KG
MCG __ Motorola Computer Group
MCI __ Micronics Computers
MCL __ Motorola Communications Israel
MCM __ Metricom Inc
MCN __ Micron Electronics Inc
MCO __ Motion Computing Inc.
MCP __ Magni Systems Inc
MCQ __ Mat's Computers
MCR __ Marina Communicaitons
MCS __ Micro Computer Systems
MCT __ Microtec
MDA __ Media4 Inc
MDC __ Midori Electronics
MDD __ MODIS
MDG __ Madge Networks
MDI __ Micro Design Inc
MDK __ Mediatek Corporation
MDO __ Panasonic
MDR __ Medar Inc
MDS __ Micro Display Systems Inc
MDT __ Magus Data Tech
MDV __ MET Development Inc
MDX __ MicroDatec GmbH
MDY __ Microdyne Inc
MEC __ Mega System Technologies Inc
MED __ Messeltronik Dresden GmbH
MEE __ Mitsubishi Electric Engineering Co., Ltd.
MEG __ Abeam Tech Ltd
MEI __ Panasonic Industry Company
MEJ __ Mac-Eight Co., LTD.
MEL __ Mitsubishi Electric Corporation
MEN __ MEN Mikroelectronik Nueruberg GmbH
MEQ __ Matelect Ltd.
MET __ Metheus Corporation
MEX __ MSC Vertriebs GmbH
MFG __ MicroField Graphics Inc
MFI __ Micro Firmware
MFR __ MediaFire Corp.
MGA __ Mega System Technologies, Inc.
MGC __ Mentor Graphics Corporation
MGE __ Schneider Electric S.A.
MGL __ M-G Technology Ltd
MGT __ Megatech R & D Company
MIC __ Micom Communications Inc
MID __ miro Displays
MII __ Mitec Inc
MIL __ Marconi Instruments Ltd
MIM __ Mimio – A Newell Rubbermaid Company
MIN __ Minicom Digital Signage
MIP __ micronpc.com
MIR __ Miro Computer Prod.
MIS __ Modular Industrial Solutions Inc
MIT __ MCM Industrial Technology GmbH
MJI __ MARANTZ JAPAN, INC.
MJS __ MJS Designs
MKC __ Media Tek Inc.
MKT __ MICROTEK Inc.
MKV __ Trtheim Technology
MLD __ Deep Video Imaging Ltd
MLG __ Micrologica AG
MLI __ McIntosh Laboratory Inc.
MLM __ Millennium Engineering Inc
MLN __ Mark Levinson
MLS __ Milestone EPE
MLX __ Mylex Corporation
MMA __ Micromedia AG
MMD __ Micromed Biotecnologia Ltd
MMF __ Minnesota Mining and Manufacturing
MMI __ Multimax
MMM __ Electronic Measurements
MMN __ MiniMan Inc
MMS __ MMS Electronics
MNC __ Mini Micro Methods Ltd
MNL __ Monorail Inc
MNP __ Microcom
MOD __ Modular Technology
MOM __ Momentum Data Systems
MOS __ Moses Corporation
MOT __ Motorola UDS
MPC __ M-Pact Inc
MPI __ Mediatrix Peripherals Inc
MPJ __ Microlab
MPL __ Maple Research Inst. Company Ltd
MPN __ Mainpine Limited
MPS __ mps Software GmbH
MPX __ Micropix Technologies, Ltd.
MQP __ MultiQ Products AB
MRA __ Miranda Technologies Inc
MRC __ Marconi Simulation & Ty-Coch Way Training
MRD __ MicroDisplay Corporation
MRK __ Maruko & Company Ltd
MRL __ Miratel
MRO __ Medikro Oy
MRT __ Merging Technologies
MSA __ Micro Systemation AB
MSC __ Mouse Systems Corporation
MSD __ Datenerfassungs- und Informationssysteme
MSF __ M-Systems Flash Disk Pioneers
MSG __ MSI GmbH
MSI __ Microstep
MSK __ Megasoft Inc
MSL __ MicroSlate Inc.
MSM __ Advanced Digital Systems
MSP __ Mistral Solutions [P] Ltd.
MST __ MS Telematica
MSU __ motorola
MSV __ Mosgi Corporation
MSX __ Micomsoft Co., Ltd.
MSY __ MicroTouch Systems Inc
MTB __ Media Technologies Ltd.
MTC __ Mars-Tech Corporation
MTD __ MindTech Display Co. Ltd
MTE __ MediaTec GmbH
MTH __ Micro-Tech Hearing Instruments
MTI __ Motorola Inc.
MTK __ Microtek International Inc.
MTL __ Mitel Corporation
MTM __ Motium
MTN __ Mtron Storage Technology Co., Ltd.
MTR __ Mitron computer Inc
MTS __ Multi-Tech Systems
MTU __ Mark of the Unicorn Inc
MTX __ Matrox
MUD __ Multi-Dimension Institute
MUK __ mainpine limited
MVD __ Microvitec PLC
MVI __ Media Vision Inc
MVM __ SOBO VISION
MVS __ Microvision
MVX __ COM 1
MWI __ Multiwave Innovation Pte Ltd
MWR __ mware
MWY __ Microway Inc
MXD __ MaxData Computer GmbH & Co.KG
MXI __ Macronix Inc
MXL __ Hitachi Maxell, Ltd.
MXP __ Maxpeed Corporation
MXT __ Maxtech Corporation
MXV __ MaxVision Corporation
MYA __ Monydata
MYR __ Myriad Solutions Ltd
MYX __ Micronyx Inc
NAC __ Ncast Corporation
NAD __ NAD Electronics
NAK __ Nakano Engineering Co.,Ltd.
NAL __ Network Alchemy
NAN __ NANAO
NAT __ NaturalPoint Inc.
NAV __ Navigation Corporation
NAX __ Naxos Tecnologia
NBL __ N*Able Technologies Inc
NBS __ National Key Lab. on ISN
NBT __ NingBo Bestwinning Technology CO., Ltd
NCA __ Nixdorf Company
NCC __ NCR Corporation
NCE __ Norcent Technology, Inc.
NCI __ NewCom Inc
NCL __ NetComm Ltd
NCR __ NCR Electronics
NCS __ Northgate Computer Systems
NCT __ NEC CustomTechnica, Ltd.
NDC __ National DataComm Corporaiton
NDI __ National Display Systems
NDK __ Naitoh Densei CO., LTD.
NDL __ Network Designers
NDS __ Nokia Data
NEC __ NEC Corporation
NEO __ NEO TELECOM CO.,LTD.
NET __ Mettler Toledo
NEU __ NEUROTEC - EMPRESA DE PESQUISA E DESENVOLVIMENTO EM BIOMEDICINA
NEX __ Nexgen Mediatech Inc.,
NFC __ BTC Korea Co., Ltd
NFS __ Number Five Software
NGC __ Network General
NGS __ A D S Exports
NHT __ Vinci Labs
NIC __ National Instruments Corporation
NIS __ Nissei Electric Company
NIT __ Network Info Technology
NIX __ Seanix Technology Inc
NLC __ Next Level Communications
NMP __ Nokia Mobile Phones
NMS __ Natural Micro System
NMV __ NEC-Mitsubishi Electric Visual Systems Corporation
NMX __ Neomagic
NNC __ NNC
NOE __ NordicEye AB
NOI __ North Invent A/S
NOK __ Nokia Display Products
NOR __ Norand Corporation
NOT __ Not Limited Inc
NPI __ Network Peripherals Inc
NRL __ U.S. Naval Research Lab
NRT __ Beijing Northern Radiantelecom Co.
NRV __ Taugagreining hf
NSC __ National Semiconductor Corporation
NSI __ NISSEI ELECTRIC CO.,LTD
NSP __ Nspire System Inc.
NSS __ Newport Systems Solutions
NST __ Network Security Technology Co
NTC __ NeoTech S.R.L
NTI __ New Tech Int'l Company
NTL __ National Transcomm. Ltd
NTN __ Nuvoton Technology Corporation
NTR __ N-trig Innovative Technologies, Inc.
NTS __ Nits Technology Inc.
NTT __ NTT Advanced Technology Corporation
NTW __ Networth Inc
NTX __ Netaccess Inc
NUG __ NU Technology, Inc.
NUI __ NU Inc.
NVC __ NetVision Corporation
NVD __ Nvidia
NVI __ NuVision US, Inc.
NVL __ Novell Inc
NVT __ Navatek Engineering Corporation
NWC __ NW Computer Engineering
NWP __ NovaWeb Technologies Inc
NWS __ Newisys, Inc.
NXC __ NextCom K.K.
NXG __ Nexgen
NXP __ NXP Semiconductors bv.
NXQ __ Nexiq Technologies, Inc.
NXS __ Technology Nexus Secure Open Systems AB
NYC __ nakayo telecommunications,inc.
OAK __ Oak Tech Inc
OAS __ Oasys Technology Company
OBS __ Optibase Technologies
OCD __ Macraigor Systems Inc
OCN __ Olfan
OCS __ Open Connect Solutions
ODM __ ODME Inc.
ODR __ Odrac
OEC __ ORION ELECTRIC CO.,LTD
OEI __ Optum Engineering Inc.
OIC __ Option Industrial Computers
OIM __ Option International
OKI __ OKI Electric Industrial Company Ltd
OLC __ Olicom A/S
OLD __ Olidata S.p.A.
OLI __ Olivetti
OLV __ Olitec S.A.
OLY __ OLYMPUS CORPORATION
OMC __ OBJIX Multimedia Corporation
OMN __ Omnitel
OMR __ Omron Corporation
ONE __ Oneac Corporation
ONK __ ONKYO Corporation
ONL __ OnLive, Inc
ONS __ On Systems Inc
ONW __ OPEN Networks Ltd
ONX __ SOMELEC Z.I. Du Vert Galanta
OOS __ OSRAM
OPC __ Opcode Inc
OPI __ D.N.S. Corporation
OPP __ OPPO Digital, Inc.
OPT __ OPTi Inc
OPV __ Optivision Inc
OQI __ OPTIQUEST
ORG __ ORGA Kartensysteme GmbH
ORI __ OSR Open Systems Resources, Inc.
ORN __ ORION ELECTRIC CO., LTD.
OSA __ OSAKA Micro Computer, Inc.
OSP __ OPTI-UPS Corporation
OSR __ Oksori Company Ltd
OTB __ outsidetheboxstuff.com
OTI __ Orchid Technology
OTM __ Optoma Corporation          
OTT __ OPTO22, Inc.
OUK __ OUK Company Ltd
OWL __ Mediacom Technologies Pte Ltd
OXU __ Oxus Research S.A.
OYO __ Shadow Systems
OZC __ OZ Corporation
OZO __ Tribe Computer Works Inc
PAC __ Pacific Avionics Corporation
PAK __ Many CNC System Co., Ltd.
PAM __ Peter Antesberger Messtechnik
PAN __ The Panda Project
PAR __ Parallan Comp Inc
PBI __ Pitney Bowes
PBL __ Packard Bell Electronics
PBN __ Packard Bell NEC
PCA __ Philips BU Add On Card
PCB __ OCTAL S.A.
PCC __ PowerCom Technology Company Ltd
PCG __ First Industrial Computer Inc
PCI __ Pioneer Computer Inc
PCK __ PCBANK21
PCL __ pentel.co.,ltd
PCM __ PCM Systems Corporation
PCO __ Performance Concepts Inc.,
PCP __ Procomp USA Inc
PCS __ TOSHIBA PERSONAL COMPUTER SYSTEM CORPRATION
PCT __ PC-Tel Inc
PCW __ Pacific CommWare Inc
PCX __ PC Xperten
PDC __ Polaroid
PDM __ Psion Dacom Plc.
PDN __ AT&T Paradyne
PDR __ Pure Data Inc
PDS __ PD Systems International Ltd
PDT __ PDTS - Prozessdatentechnik und Systeme
PDV __ Prodrive B.V.
PEC __ POTRANS Electrical Corp.
PEI __ PEI Electronics Inc
PEL __ Primax Electric Ltd
PEN __ Interactive Computer Products Inc
PEP __ Peppercon AG
PER __ Perceptive Signal Technologies
PET __ Practical Electronic Tools
PFT __ Telia ProSoft AB
PGI __ PACSGEAR, Inc.
PGM __ Paradigm Advanced Research Centre
PGP __ propagamma kommunikation
PGS __ Princeton Graphic Systems
PHC __ Pijnenburg Beheer N.V.
PHE __ Philips Medical Systems Boeblingen GmbH
PHI __ PHI
PHL __ Philips Consumer Electronics Company
PHO __ Photonics Systems Inc.
PHS __ Philips Communication Systems
PHY __ Phylon Communications
PIE __ Pacific Image Electronics Company Ltd
PIM __ Prism, LLC
PIO __ Pioneer Electronic Corporation
PIX __ Pixie Tech Inc
PJA __ Projecta
PJD __ Projectiondesign AS
PJT __ Pan Jit International Inc.
PKA __ Acco UK ltd.
PLC __ Pro-Log Corporation
PLF __ Panasonic Avionics Corporation
PLM __ PROLINK Microsystems Corp.
PLT __ PT Hartono Istana Teknologi
PLV __ PLUS Vision Corp.
PLX __ Parallax Graphics
PLY __ Polycom Inc.
PMC __ PMC Consumer Electronics Ltd
PMM __ Point Multimedia System
PMT __ Promate Electronic Co., Ltd.
PMX __ Photomatrix
PNG __ P.I. Engineering Inc
PNL __ Panelview, Inc.
PNR __ Planar Systems, Inc.
PNS __ PanaScope
PNX __ Phoenix Technologies, Ltd.
POL __ PolyComp (PTY) Ltd.
PON __ Perpetual Technologies, LLC
POR __ Portalis LC
PPC __ Phoenixtec Power Company Ltd
PPD __ MEPhI
PPI __ Practical Peripherals
PPM __ Clinton Electronics Corp.
PPP __ Purup Prepress AS
PPR __ PicPro
PPX __ Perceptive Pixel Inc.
PQI __ Pixel Qi
PRA __ PRO/AUTOMATION
PRC __ PerComm
PRD __ Praim S.R.L.
PRF __ Digital Electronics Corporation
PRG __ The Phoenix Research Group Inc
PRI __ Priva Hortimation BV
PRM __ Prometheus
PRO __ Proteon
PRS __ Leutron Vision
PRT __ Parade Technologies, Ltd.
PRX __ Proxima Corporation
PSA __ Advanced Signal Processing Technologies
PSC __ Philips Semiconductors
PSD __ Peus-Systems GmbH
PSE __ Practical Solutions Pte., Ltd.
PSI __ PSI-Perceptive Solutions Inc
PSL __ Perle Systems Limited
PSM __ Prosum
PST __ Global Data SA
PTA __ PAR Tech Inc.
PTC __ PS Technology Corporation
PTG __ Cipher Systems Inc
PTH __ Pathlight Technology Inc
PTI __ Promise Technology Inc
PTL __ Pantel Inc
PTS __ Plain Tree Systems Inc
PTW __ PTW
PVC __ PVC
PVG __ Proview Global Co., Ltd
PVI __ Prime view international Co., Ltd
PVM __ Penta Studiotechnik GmbH
PVN __ Pixel Vision
PVP __ Klos Technologies, Inc.
PXC __ Phoenix Contact
PXE __ PIXELA CORPORATION
PXL __ The Moving Pixel Company
PXM __ Proxim Inc
QCC __ QuakeCom Company Ltd
QCH __ Metronics Inc
QCI __ Quanta Computer Inc
QCK __ Quick Corporation
QCL __ Quadrant Components Inc
QCP __ Qualcomm Inc
QDI __ Quantum Data Incorporated
QDM __ Quadram
QDS __ Quanta Display Inc.
QFF __ Padix Co., Inc.
QFI __ Quickflex, Inc
QLC __ Q-Logic
QQQ __ Chuomusen Co., Ltd.
QSI __ Quantum Solutions, Inc.
QTD __ Quantum 3D Inc
QTH __ Questech Ltd
QTI __ Quicknet Technologies Inc
QTM __ Quantum
QTR __ Qtronix Corporation
QUA __ Quatographic AG
QUE __ Questra Consulting
QVU __ Quartics
RAC __ Racore Computer Products Inc
RAD __ Radisys Corporation
RAI __ Rockwell Automation/Intecolor
RAR __ Raritan, Inc.
RAS __ RAScom Inc
RAT __ Rent-A-Tech
RAY __ Raylar Design, Inc.
RCE __ Parc d'Activite des Bellevues
RCH __ Reach Technology Inc
RCI __ RC International
RCN __ Radio Consult SRL
RCO __ Rockwell Collins
RDI __ Rainbow Displays, Inc.
RDM __ Tremon Enterprises Company Ltd
RDN __ RADIODATA GmbH
RDS __ Radius Inc
REA __ Real D
REC __ ReCom
RED __ Research Electronics Development Inc
REF __ Reflectivity, Inc.
REH __ Rehan Electronics Ltd.
REL __ Reliance Electric Ind Corporation
REM __ SCI Systems Inc.
REN __ Renesas Technology Corp.
RES __ ResMed Pty Ltd
RET __ Resonance Technology, Inc.
REX __ RATOC Systems, Inc.
RGL __ Robertson Geologging Ltd
RHD __ RightHand Technologies
RHM __ Rohm Company Ltd
RHT __ Red Hat, Inc.
RIC __ RICOH COMPANY, LTD.
RII __ Racal Interlan Inc
RIO __ Rios Systems Company Ltd
RIT __ Ritech Inc
RIV __ Rivulet Communications
RJA __ Roland Corporation
RJS __ Advanced Engineering
RKC __ Reakin Technolohy Corporation
RLD __ MEPCO
RLN __ RadioLAN Inc
RMC __ Raritan Computer, Inc
RMP __ Research Machines
RMT __ Roper Mobile
RNB __ Rainbow Technologies
ROB __ Robust Electronics GmbH
ROH __ Rohm Co., Ltd.
ROK __ Rockwell International
ROP __ Roper International Ltd
ROS __ Rohde & Schwarz
RPI __ RoomPro Technologies
RPT __ R.P.T.Intergroups
RRI __ Radicom Research Inc
RSC __ PhotoTelesis
RSH __ ADC-Centre
RSI __ Rampage Systems Inc
RSN __ Radiospire Networks, Inc.
RSQ __ R Squared
RSS __ Rockwell Semiconductor Systems
RSV __ Ross Video Ltd
RSX __ Rapid Tech Corporation
RTC __ Relia Technologies
RTI __ Rancho Tech Inc
RTK __ RTK
RTL __ Realtek Semiconductor Company Ltd
RTS __ Raintree Systems
RUN __ RUNCO International
RUP __ Ups Manufactoring s.r.l.
RVC __ RSI Systems Inc
RVI __ Realvision Inc
RVL __ Reveal Computer Prod
RWC __ Red Wing Corporation
RXT __ Tectona SoftSolutions (P) Ltd.,
SAA __ Sanritz Automation Co.,Ltd.
SAE __ Saab Aerotech
SAG __ Sedlbauer
SAI __ Sage Inc
SAK __ Saitek Ltd
SAM __ Samsung Electric Company
SAN __ Sanyo Electric Co.,Ltd.
SAS __ Stores Automated Systems Inc
SAT __ Shuttle Tech
SBC __ Shanghai Bell Telephone Equip Mfg Co
SBD __ Softbed - Consulting & Development Ltd
SBI __ SMART Technologies Inc.
SBS __ SBS-or Industrial Computers GmbH
SBT __ Senseboard Technologies AB
SCC __ SORD Computer Corporation
SCE __ Sun Corporation
SCH __ Schlumberger Cards
SCI __ System Craft
SCL __ Sigmacom Co., Ltd.
SCM __ SCM Microsystems Inc
SCN __ Scanport, Inc.
SCO __ SORCUS Computer GmbH
SCP __ Scriptel Corporation
SCR __ Systran Corporation
SCS __ Nanomach Anstalt
SCT __ Smart Card Technology
SDA __ SAT (Societe Anonyme)
SDD __ Intrada-SDD Ltd
SDE __ Sherwood Digital Electronics Corporation
SDF __ SODIFF E&T CO., Ltd.
SDH __ Communications Specialies, Inc.
SDI __ Samtron Displays Inc
SDK __ SAIT-Devlonics
SDR __ SDR Systems
SDS __ SunRiver Data System
SDT __ Siemens AG
SDX __ SDX Business Systems Ltd
SEA __ Seanix Technology Inc.
SEB __ system elektronik GmbH
SEC __ Seiko Epson Corporation
SEE __ SeeColor Corporation
SEG __ SEG
SEI __ Seitz & Associates Inc
SEL __ Way2Call Communications
SEM __ Samsung Electronics Company Ltd
SEN __ Sencore
SEO __ SEOS Ltd
SEP __ SEP Eletronica Ltda.
SER __ Sony Ericsson Mobile Communications Inc.
SES __ Session Control LLC
SET __ SendTek Corporation
SFM __ TORNADO Company
SFT __ Mikroforum Ring 3
SGC __ Spectragraphics Corporation
SGD __ Sigma Designs, Inc.
SGE __ Kansai Electric Company Ltd
SGI __ Scan Group Ltd
SGL __ Super Gate Technology Company Ltd
SGM __ SAGEM
SGO __ Logos Design A/S
SGT __ Stargate Technology
SGW __ Shanghai Guowei Science and Technology Co., Ltd.
SGX __ Silicon Graphics Inc
SGZ __ Systec Computer GmbH
SHC __ ShibaSoku Co., Ltd.
SHG __ Soft & Hardware development Goldammer GmbH
SHI __ Jiangsu Shinco Electronic Group Co., Ltd
SHP __ Sharp Corporation
SHR __ Digital Discovery
SHT __ Shin Ho Tech
SIA __ SIEMENS AG
SIC __ Sysmate Corporation
SID __ Seiko Instruments Information Devices Inc
SIE __ Siemens
SIG __ Sigma Designs Inc
SII __ Silicon Image, Inc.
SIL __ Silicon Laboratories, Inc
SIN __ Singular Technology Co., Ltd.
SIR __ Sirius Technologies Pty Ltd
SIS __ Silicon Integrated Systems Corporation
SIT __ Sitintel
SIU __ Seiko Instruments USA Inc
SIX __ Zuniq Data Corporation
SJE __ Sejin Electron Inc
SKD __ Schneider & Koch
SKT __ Samsung Electro-Mechanics Company Ltd
SKY __ SKYDATA S.P.A.
SLA __ Systeme Lauer GmbH&Co KG
SLB __ Shlumberger Ltd
SLC __ Syslogic Datentechnik AG
SLF __ StarLeaf
SLH __ Silicon Library Inc.
SLI __ Symbios Logic Inc
SLK __ Silitek Corporation
SLM __ Solomon Technology Corporation
SLR __ Schlumberger Technology Corporate
SLS __ Schnick-Schnack-Systems GmbH
SLT __ Salt Internatioinal Corp.
SLX __ Specialix
SMA __ SMART Modular Technologies
SMB __ Schlumberger
SMC __ Standard Microsystems Corporation
SME __ Sysmate Company
SMI __ SpaceLabs Medical Inc
SMK __ SMK CORPORATION
SML __ Sumitomo Metal Industries, Ltd.
SMM __ Shark Multimedia Inc
SMO __ STMicroelectronics
SMP __ Simple Computing
SMR __ B.& V. s.r.l.
SMS __ Silicom Multimedia Systems Inc
SMT __ Silcom Manufacturing Tech Inc
SNC __ Sentronic International Corp.
SNI __ Siemens Microdesign GmbH
SNK __ S&K Electronics
SNO __ SINOSUN TECHNOLOGY CO., LTD
SNP __ Siemens Nixdorf Info Systems
SNS __ Cirtech (UK) Ltd
SNT __ SuperNet Inc
SNW __ Snell & Wilcox
SNX __ Sonix Comm. Ltd
SNY __ Sony Corporation
SOI __ Silicon Optix Corporation
SOL __ Solitron Technologies Inc
SON __ Sony
SOR __ Sorcus Computer GmbH
SOT __ Sotec Company Ltd
SOY __ SOYO Group, Inc
SPC __ SpinCore Technologies, Inc
SPE __ SPEA Software AG
SPH __ G&W Instruments GmbH
SPI __ SPACE-I Co., Ltd.
SPK __ SpeakerCraft
SPL __ Smart Silicon Systems Pty Ltd
SPN __ Sapience Corporation
SPR __ pmns GmbH
SPS __ Synopsys Inc
SPT __ Sceptre Tech Inc
SPU __ SIM2 Multimedia S.P.A.
SPX __ Simplex Time Recorder Co.
SQT __ Sequent Computer Systems Inc
SRC __ Integrated Tech Express Inc
SRD __ Setred
SRF __ Surf Communication Solutions Ltd
SRG __ Intuitive Surgical, Inc.
SRT __ SeeReal Technologies GmbH
SSC __ Sierra Semiconductor Inc
SSD __ FlightSafety International
SSE __ Samsung Electronic Co.
SSI __ S-S Technology Inc
SSJ __ Sankyo Seiki Mfg.co., Ltd
SSP __ Spectrum Signal Proecessing Inc
SSS __ S3 Inc
SST __ SystemSoft Corporation
STA __ ST Electronics Systems Assembly Pte Ltd
STB __ STB Systems Inc
STC __ STAC Electronics
STD __ STD Computer Inc
STE __ SII Ido-Tsushin Inc
STF __ Starflight Electronics
STG __ StereoGraphics Corp.
STH __ Semtech Corporation
STI __ Smart Tech Inc
STK __ SANTAK CORP.
STL __ SigmaTel Inc
STM __ SGS Thomson Microelectronics
STN __ Samsung Electronics America
STO __ Stollmann E+V GmbH
STP __ StreamPlay Ltd
STR __ Starlight Networks Inc
STS __ SITECSYSTEM CO., LTD.
STT __ Star Paging Telecom Tech (Shenzhen) Co. Ltd.
STU __ Sentelic Corporation
STW __ Starwin Inc.
STX __ ST-Ericsson
STY __ SDS Technologies
SUB __ Subspace Comm. Inc
SUM __ Summagraphics Corporation
SUN __ Sun Electronics Corporation
SUP __ Supra Corporation
SUR __ Surenam Computer Corporation
SVA __ SGEG
SVC __ Intellix Corp.
SVD __ SVD Computer
SVI __ Sun Microsystems
SVS __ SVSI
SVT __ SEVIT Co., Ltd.
SWC __ Software Café
SWI __ Sierra Wireless Inc.
SWL __ Sharedware Ltd
SWS __ Static
SWT __ Software Technologies Group,Inc.
SXB __ Syntax-Brillian
SXD __ Silex technology, Inc.
SXL __ SolutionInside
SXT __ SHARP TAKAYA ELECTRONIC INDUSTRY CO.,LTD.
SYC __ Sysmic
SYE __ SY Electronics Ltd
SYK __ Stryker Communications
SYL __ Sylvania Computer Products
SYM __ Symicron Computer Communications Ltd.
SYN __ Synaptics Inc
SYP __ SYPRO Co Ltd
SYS __ Sysgration Ltd
SYT __ Seyeon Tech Company Ltd
SYV __ SYVAX Inc
SYX __ Prime Systems, Inc.
TAA __ Tandberg
TAB __ Todos Data System AB
TAG __ Teles AG
TAM __ Tamura Seisakusyo Ltd
TAS __ Taskit Rechnertechnik GmbH
TAT __ Teleliaison Inc
TAX __ Taxan (Europe) Ltd
TBB __ Triple S Engineering Inc
TBC __ Turbo Communication, Inc
TBS __ Turtle Beach System
TCC __ Tandon Corporation
TCD __ Taicom Data Systems Co., Ltd.
TCE __ Century Corporation
TCH __ Interaction Systems, Inc
TCI __ Tulip Computers Int'l B.V.
TCJ __ TEAC America Inc
TCL __ Technical Concepts Ltd
TCM __ 3Com Corporation
TCN __ Tecnetics (PTY) Ltd
TCO __ Thomas-Conrad Corporation
TCR __ Thomson Consumer Electronics
TCS __ Tatung Company of America Inc
TCT __ Telecom Technology Centre Co. Ltd.
TCX __ FREEMARS Heavy Industries
TDC __ Teradici
TDD __ Tandberg Data Display AS
TDK __ TDK USA Corporation
TDM __ Tandem Computer Europe Inc
TDP __ 3D Perception
TDS __ Tri-Data Systems Inc
TDT __ TDT
TDV __ TDVision Systems, Inc.
TDY __ Tandy Electronics
TEA __ TEAC System Corporation
TEC __ Tecmar Inc
TEK __ Tektronix Inc
TEL __ Promotion and Display Technology Ltd.
TER __ TerraTec Electronic GmbH
TGC __ Toshiba Global Commerce Solutions, Inc.
TGI __ TriGem Computer Inc
TGM __ TriGem Computer,Inc.
TGV __ Grass Valley Germany GmbH
THN __ Thundercom Holdings Sdn. Bhd.
TIC __ Trigem KinfoComm
TIP __ TIPTEL AG
TIV __ OOO Technoinvest
TIX __ Tixi.Com GmbH
TKC __ Taiko Electric Works.LTD
TKN __ Teknor Microsystem Inc
TKO __ TouchKo, Inc.
TKS __ TimeKeeping Systems, Inc.
TLA __ Ferrari Electronic GmbH
TLD __ Telindus
TLI __ TOSHIBA TELI CORPORATION
TLK __ Telelink AG
TLS __ Teleste Educational OY
TLT __ Dai Telecom S.p.A.
TLX __ Telxon Corporation
TMC __ Techmedia Computer Systems Corporation
TME __ AT&T Microelectronics
TMI __ Texas Microsystem
TMM __ Time Management, Inc.
TMR __ Taicom International Inc
TMS __ Trident Microsystems Ltd
TMT __ T-Metrics Inc.
TMX __ Thermotrex Corporation
TNC __ TNC Industrial Company Ltd
TNJ __ TNJ
TNM __ TECNIMAGEN SA
TNY __ Tennyson Tech Pty Ltd
TOE __ TOEI Electronics Co., Ltd.
TOG __ The OPEN Group
TON __ TONNA
TOP __ Orion Communications Co., Ltd.
TOS __ Toshiba Corporation
TOU __ Touchstone Technology
TPC __ Touch Panel Systems Corporation
TPE __ Technology Power Enterprises Inc
TPJ __ Junnila
TPK __ TOPRE CORPORATION
TPR __ Topro Technology Inc
TPS __ Teleprocessing Systeme GmbH
TPT __ Thruput Ltd
TPV __ Top Victory Electronics ( Fujian ) Company Ltd
TPZ __ Ypoaz Systems Inc
TRA __ TriTech Microelectronics International
TRC __ Trioc AB
TRD __ Trident Microsystem Inc
TRE __ Tremetrics
TRI __ Tricord Systems
TRL __ Royal Information
TRM __ Tekram Technology Company Ltd
TRN __ Datacommunicatie Tron B.V.
TRS __ Torus Systems Ltd
TRT __ Tritec Electronic AG
TRU __ Aashima Technology B.V.
TRV __ Trivisio Prototyping GmbH
TRX __ Trex Enterprises
TSB __ Toshiba America Info Systems Inc
TSC __ Sanyo Electric Company Ltd
TSD __ TechniSat Digital GmbH
TSE __ Tottori Sanyo Electric
TSF __ Racal-Airtech Software Forge Ltd
TSG __ The Software Group Ltd
TSI __ TeleVideo Systems
TSL __ Tottori SANYO Electric Co., Ltd.
TSP __ U.S. Navy
TST __ Transtream Inc
TSV __ TRANSVIDEO
TSY __ TouchSystems
TTA __ Topson Technology Co., Ltd.
TTB __ National Semiconductor Japan Ltd
TTC __ Telecommunications Techniques Corporation
TTE __ TTE, Inc.
TTI __ Trenton Terminals Inc
TTK __ Totoku Electric Company Ltd
TTL __ 2-Tel B.V.
TTS __ TechnoTrend Systemtechnik GmbH
TTY __ TRIDELITY Display Solutions GmbH
TUT __ Tut Systems
TVD __ Tecnovision
TVI __ Truevision
TVM __ Taiwan Video & Monitor Corporation
TVO __ TV One Ltd
TVR __ TV Interactive Corporation
TVS __ TVS Electronics Limited
TVV __ TV1 GmbH
TWA __ Tidewater Association
TWE __ Kontron Electronik
TWH __ Twinhead International Corporation
TWI __ Easytel oy
TWK __ TOWITOKO electronics GmbH
TWX __ TEKWorx Limited
TXL __ Trixel Ltd
TXN __ Texas Insturments
TXT __ Textron Defense System
TYN __ Tyan Computer Corporation
UAS __ Ultima Associates Pte Ltd
UBI __ Ungermann-Bass Inc
UBL __ Ubinetics Ltd.
UDN __ Uniden Corporation
UEC __ Ultima Electronics Corporation
UEG __ Elitegroup Computer Systems Company Ltd
UEI __ Universal Electronics Inc
UET __ Universal Empowering Technologies
UFG __ UNIGRAF-USA
UFO __ UFO Systems Inc
UHB __ XOCECO
UIC __ Uniform Industrial Corporation
UJR __ Ueda Japan Radio Co., Ltd.
ULT __ Ultra Network Tech
UMC __ United Microelectr Corporation
UMG __ Umezawa Giken Co.,Ltd
UMM __ Universal Multimedia
UNA __ Unisys DSD
UND __ UND
UNE __ UNE
UNF __ UNF
UNI __ Uniform Industry Corp.
UNM __ Unisys Corporation
UNP __ Unitop
UNT __ Unisys Corporation
UNY __ Unicate
UPP __ UPPI
UPS __ Systems Enhancement
URD __ Video Computer S.p.A.
USA __ Utimaco Safeware AG
USD __ U.S. Digital Corporation
USI __ Universal Scientific Industrial Co., Ltd.
USR __ U.S. Robotics Inc
UTD __ Up to Date Tech
UWC __ Uniwill Computer Corp.
VAL __ Valence Computing Corporation
VAR __ Varian Australia Pty Ltd
VBR __ VBrick Systems Inc.
VBT __ Valley Board Ltda
VCC __ Virtual Computer Corporation
VCI __ VistaCom Inc
VCJ __ Victor Company of Japan, Limited
VCM __ Vector Magnetics, LLC
VCX __ VCONEX
VDA __ Victor Data Systems
VDC __ VDC Display Systems
VDM __ Vadem
VDO __ Video & Display Oriented Corporation
VDS __ Vidisys GmbH & Company
VDT __ Viditec, Inc.
VEC __ Vector Informatik GmbH
VEK __ Vektrex
VES __ Vestel Elektronik Sanayi ve Ticaret A. S.
VFI __ VeriFone Inc
VHI __ Macrocad Development Inc.
VIA __ VIA Tech Inc
VIB __ Tatung UK Ltd
VIC __ Victron B.V.
VID __ Ingram Macrotron Germany
VIK __ Viking Connectors
VIN __ Vine Micros Ltd
VIR __ Visual Interface, Inc
VIS __ Visioneer
VIT __ Visitech AS
VIZ __ VIZIO, Inc
VLB __ ValleyBoard Ltda.
VLT __ VideoLan Technologies
VMI __ Vermont Microsystems
VML __ Vine Micros Limited
VMW __ VMware Inc.,
VNC __ Vinca Corporation
VOB __ MaxData Computer AG
VPI __ Video Products Inc
VPR __ Best Buy
VQ@ __ Vision Quest
VRC __ Virtual Resources Corporation
VSC __ ViewSonic Corporation
VSD __ 3M
VSI __ VideoServer
VSN __ Ingram Macrotron
VSP __ Vision Systems GmbH
VSR __ V-Star Electronics Inc.
VTC __ VTel Corporation
VTG __ Voice Technologies Group Inc
VTI __ VLSI Tech Inc
VTK __ Viewteck Co., Ltd.
VTL __ Vivid Technology Pte Ltd
VTM __ Miltope Corporation
VTN __ VIDEOTRON CORP.
VTS __ VTech Computers Ltd
VTV __ VATIV Technologies
VTX __ Vestax Corporation
VUT __ Vutrix (UK) Ltd
VWB __ Vweb Corp.
WAC __ Wacom Tech
WAL __ Wave Access
WAN __ WAN
WAV __ Wavephore
WBN __ MicroSoftWare
WBS __ WB Systemtechnik GmbH
WCI __ Wisecom Inc
WCS __ Woodwind Communications Systems Inc
WDC __ Western Digital
WDE __ Westinghouse Digital Electronics
WEB __ WebGear Inc
WEC __ Winbond Electronics Corporation
WEY __ WEY Design AG
WHI __ Whistle Communications
WII __ Innoware Inc
WIL __ WIPRO Information Technology Ltd
WIN __ Wintop Technology Inc
WIP __ Wipro Infotech
WKH __ Uni-Take Int'l Inc.
WLD __ Wildfire Communications Inc
WML __ Wolfson Microelectronics Ltd
WMO __ Westermo Teleindustri AB
WMT __ Winmate Communication Inc
WNI __ WillNet Inc.
WNV __ Winnov L.P.
WNX __ Wincor Nixdorf International GmbH
WPA __ Matsushita Communication Industrial Co., Ltd.
WPI __ Wearnes Peripherals International (Pte) Ltd
WRC __ WiNRADiO Communications
WSC __ CIS Technology Inc
WSP __ Wireless And Smart Products Inc.
WST __ Wistron Corporation
WTC __ ACC Microelectronics
WTI __ WorkStation Tech
WTK __ Wearnes Thakral Pte
WTS __ Restek Electric Company Ltd
WVM __ Wave Systems Corporation
WWV __ World Wide Video, Inc.
WXT __ Woxter Technology Co. Ltd
WYS __ Myse Technology
WYT __ Wooyoung Image & Information Co.,Ltd.
XAC __ XAC Automation Corp
XAD __ Alpha Data
XDM __ XDM Ltd.
XER __ XER
XFG __ Jan Strapko - FOTO
XFO __ EXFO Electro Optical Engineering
XIN __ Xinex Networks Inc
XIO __ Xiotech Corporation
XIR __ Xirocm Inc
XIT __ Xitel Pty ltd
XLX __ Xilinx, Inc.
XMM __ C3PO S.L.
XNT __ XN Technologies, Inc.
XOC __ XOC
XQU __ SHANGHAI SVA-DAV ELECTRONICS CO., LTD
XRC __ Xircom Inc
XRO __ XORO ELECTRONICS (CHENGDU) LIMITED
XSN __ Xscreen AS
XST __ XS Technologies Inc
XSY __ XSYS
XTE __ X2E GmbH
XTL __ Crystal Computer
XTN __ X-10 (USA) Inc
XYC __ Xycotec Computer GmbH
YED __ Y-E Data Inc
YHQ __ Yokogawa Electric Corporation
YHW __ Exacom SA
YMH __ Yamaha Corporation
YOW __ American Biometric Company
ZAN __ Zandar Technologies plc
ZAX __ Zefiro Acoustics
ZAZ __ Zazzle Technologies
ZBR __ Zebra Technologies International, LLC
ZCM __ Zenith Data Systems
ZCT __ ZeitControl cardsystems GmbH
ZIC __ Nationz Technologies Inc.
ZMT __ Zalman Tech Co., Ltd.
ZMZ __ Z Microsystems
ZNI __ Zetinet Inc
ZNX __ Znyx Adv. Systems
ZOW __ Zowie Intertainment, Inc
ZRN __ Zoran Corporation
ZSE __ Zenith Data Systems
ZTC __ ZyDAS Technology Corporation
ZTE __ ZTE Corporation
ZTI __ Zoom Telephonics Inc
ZTM __ ZT Group Int'l Inc.
ZTT __ Z3 Technology
ZYD __ Zydacron Inc
ZYP __ Zypcom Inc
ZYT __ Zytex Computers
ZYX __ Zyxel
inu __ Inovatec S.p.A.
