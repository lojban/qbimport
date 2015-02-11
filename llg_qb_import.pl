#!/usr/bin/perl

use Modern::Perl '2012';
use Text::CSV;
use File::Slurp;
use Data::Dumper;
use List::MoreUtils qw{ zip };

# NB: Negative quantities:  According to the QB help,
# " Debit amounts are always positive, credit amounts are always
# negative.", but if you enter things like that with positive
# quantities, you end up with positive amounts but negative
# quantities (!) in the final result; using negative quantitie to go
# with negative prices/amounts seems to fix this.

my $CLL_PRICE = 25.00;

# Massage dates From: MM/DD/YYYY To: MM/DD/YY
sub format_date {
  my $date = shift;
  die "bad date: $date" unless $date =~ m{(\d{1,2})\/(\d{1,2})\/(\d{2})(\d{2})};
  sprintf("%0.2d/%0.2d/%0.2d", $1, $2, $4);
}

#**************************************
# BEGIN Declarations
#**************************************

# These are subroutines that check themselves against a paypal
# line's data, and then do stuff if they think they apply.
my @pp_alternatives = (
  sub {
    my ($data) = @_;
    if ($data->{'Subject'} =~ m/donation/i ) {
      my %temp;
      @temp{'Date', 'Subject', 'From Email Address', 'Gross'} = @{$data}{'Date', 'Subject', 'From Email Address', 'Gross'};
      return ["a donation", \%temp, qb_customer($data, 'N') . qb_trans($data, 'N', 'donation' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Type'} eq 'Add Funds from a Bank Account') {
      my %temp;
      @temp{'Date', 'Type', 'Payment Type', 'Gross'} = @{$data}{'Date', 'Type', 'Payment Type', 'Gross'};
      return ["a transfer from the main account to the paypal account", \%temp, qb_trans($data, 'N', 'main_to_paypal' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Type'} eq 'Update to eCheck Received') {
      my %temp;
      @temp{'Date', 'Type', 'From Email Address', 'Gross'} = @{$data}{'Date', 'Type', 'From Email Address', 'Gross'};
      return ["some crap we should throw out", \%temp, '' ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Type'} eq 'Update to eCheck Sent') {
      my %temp;
      @temp{'Date', 'Type', 'From Email Address', 'Gross'} = @{$data}{'Date', 'Type', 'From Email Address', 'Gross'};
      return ["some crap we should throw out", \%temp, '' ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Type'} eq 'eCheck Sent') {
      my %temp;
      @temp{'Date', 'Type', 'To Email Address', 'Gross'} = @{$data}{'Date', 'Type', 'To Email Address', 'Gross'};
      return ["a special-case one-time payment to someone", \%temp, qb_customer($data, 'N') . qb_trans($data, 'N', 'direct_paypal' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Type'} =~ /Withdraw Funds to (a )?Bank Account/) {
      my %temp;
      @temp{'Date', 'Type', 'Gross'} = @{$data}{'Date', 'Type', 'Gross'};
      return ["a transfer from the paypal account to the main account", \%temp, qb_trans($data, 'N', 'paypal_to_main' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if( $data->{'Item Title'} =~ m/Complete Lojban Language/ && $data->{'Type'} eq 'Web Accept Payment Received' && $data->{'Shipping Address'} =~ m/(VA|Virginia)/ ) {
      my %temp;
      @temp{'Date', 'Item Title', 'Gross', 'Shipping Address', 'From Email Address'} = @{$data}{'Date', 'Item Title', 'Gross', 'Shipping Address', 'From Email Address'};
      return ["a CLL purchase to a TAXABLE address", \%temp, qb_customer($data, 'Y') . qb_trans($data, 'Y', 'cll' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if( $data->{'Item Title'} =~ m/Complete Lojban Language/ && $data->{'Type'} eq 'Web Accept Payment Received' ) {
      my %temp;
      @temp{'Date', 'Item Title', 'Gross', 'Shipping Address', 'From Email Address'} = @{$data}{'Date', 'Item Title', 'Gross', 'Shipping Address', 'From Email Address'};
      return ["a CLL purchase to a NON-TAXABLE address", \%temp, qb_customer($data, 'N') . qb_trans($data, 'N', 'cll' ) ];
    } else {
      return;
    }
  },
);

# These are subroutines that check themselves against a Well Fargo
# line's data, and then do stuff if they think they apply.
my @wf_alternatives = (
  sub {
    # Transfers FROM the main account; handled on the paypal side
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^PAYPAL ECHECK/ ) {
      return ["a transfer from the main account to paypal, already handled on the paypal side", $data, '' ];
    } else {
      return;
    }
  },
  sub {
    # Transfers TO the main account; handled on the paypal side
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^PAYPAL TRANSFER/ ) {
      return ["a transfer from paypal to the main account, already handled on the paypal side", $data, '' ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^AMAZON.COM/ ) {
      return ["an Amazon book sale deposit", $data, qb_direct_main($data, 'Amazon.Com Seller Account' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^LSI/ ) {
      return ["a Lightning Source deposit", $data, qb_direct_main($data, 'Lightning Source' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^CHECK CRD PURCHASE \S+ USPS / ) {
      return ["a credit card postage purchase", $data, qb_trans($data, 'N', 'postage_main' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^CHECK CRD PURCHASE \S+ (OPC )?VIRGINIA SCC / ) {
      return ["the annual corporation filings, paid by credit card", $data, qb_trans($data, 'N', 'corp_main' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^POS PURCHASE - Staples Inc FAIRFAX/ ) {
      return ["a credit card postage purchase", $data, qb_trans($data, 'N', 'postage_main' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^POS PURCHASE - USPS/ ) {
      return ["a credit card postage purchase", $data, qb_trans($data, 'N', 'postage_main' ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^CHECK CRD PURCHASE \S+ AMAZON MKTPLACE PM AMZN.COM.BILL/ ) {
      my $date=$data->{'Date'};
      $date = format_date($date);

      my $amount=$data->{'Gross'};
      $amount =~ s/^ *-*//;
      return ["a bill for our Amazon seller account", $data, qb_bill( $date, $amount, "Main Account", "Miscellaneous", 'Amazon.Com Seller Account', "Other Expense" ) ];
    } else {
      return;
    }
  },
  sub {
    my ($data) = @_;
    if ($data->{'Description'} =~ m/^CHECK CRD PURCHASE \S+ LIGHTNING SOURCE/ ) {
      my $date=$data->{'Date'};
      $date = format_date($date);

      my $amount=$data->{'Gross'};
      $amount =~ s/^ *-*//;
      return ["a bill for our Lightning Source account", $data, qb_bill( $date, $amount, "Main Account", "Miscellaneous", 'Lightning Source', "Other Expense" ) ];
    } else {
      return;
    }
  },
);

sub qb_direct_main {
  my ($data, $customer) = @_;

  my $date=$data->{'Date'};
  $date = format_date($date);

  my $amount=$data->{'Gross'};
  $amount =~ s/^ *-*//;

  my @transheaders = qw{!TRNS TRNSTYPE DATE ACCNT NAME CLASS AMOUNT NAMEISTAXABLE};
  my $stuff = join("\t", @transheaders)."\n";

  my @splheaders = qw{!SPL TRNSTYPE DATE ACCNT NAME CLASS AMOUNT TAXABLE SPLID};
  $stuff .= join("\t", @splheaders)."\n";

  $stuff .= "!ENDTRNS\n";

  $stuff .= join("\t", ( "TRNS",
      "DEPOSIT",
      "$date",
      "Main Account",
      "",
      "",
      "$amount",
      "N",  # No taxes on paypal fees
    ))."\n";

  $stuff .= join("\t", ( "SPL",
      "DEPOSIT",
      "$date",
      "$customer",
      "$customer",
      "",
      "-$amount",
      "N",  # No taxes on paypal fees
      "1",
    ))."\n";

  $stuff .= "ENDTRNS\n";

  return $stuff;
};

sub qb_bill {
  my ($date, $amount, $to_account, $from_account, $name, $class ) = @_;

  my @transheaders = qw{!TRNS TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT NAMEISTAXABLE};
  my $stuff = join("\t", @transheaders)."\n";

  my @splheaders = qw{!SPL TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT TAXABLE SPLID};
  $stuff .= join("\t", @splheaders)."\n";

  $stuff .= "!ENDTRNS\n";

  $stuff .= join("\t", ( "TRNS",
      "CHECK",
      "$date",
      "$date",
      "$to_account",
      "$name",
      "$class",
      "-$amount",
      "N",  # No taxes on paypal fees
    ))."\n";

  $stuff .= join("\t", ( "SPL",
      "CHECK",
      "$date",
      "$date",
      "$from_account",
      "$name",
      "$class",
      "$amount",
      "N",  # No taxes on paypal fees
      "1",
    ))."\n";

  $stuff .= "ENDTRNS\n";

  return $stuff;
};

sub qb_trans {
  my ($data, $taxable, $type ) = @_;

  my @transheaders = qw{!TRNS MEMO NAME AMOUNT NAMEISTAXABLE ACCNT FIRSTNAME LASTNAME DATE CLASS TRNSTYPE};
  my $stuff = join("\t", @transheaders)."\n";

  my @splheaders = qw{!SPL MEMO NAME AMOUNT TAXABLE ACCNT SPLID INVITEM QNTY PRICE EXTRA};
  $stuff .= join("\t", @splheaders)."\n";

  $stuff .= "!ENDTRNS\n";

  my $name = $data->{'Name'};
  my $name_swapped = '';
  my $firstname = '';
  my $lastname = '';

  if( $name ) {
    # Comma-splice the name
    $name_swapped = $name;
    $name_swapped =~ s/\s*([^\s]*)\s+(.*)/$2, $1/;
    $firstname = $1;
    $lastname = $2;
  }

  my $date=$data->{'Date'};
  $date = format_date($date);

  my $gross=$data->{'Gross'};
  $gross =~ s/^ *-*//;

  if( $type eq 'donation' ) {
    $stuff .= join("\t", ( "TRNS",
        "Donation",
        "$name_swapped",
        "$gross",
        "N",
        "PayPal",
        "$firstname", "$lastname",
        "$date",
        "Donation",
        "CASH SALE",
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Donation",
        "$name_swapped",
        "-$gross",
        "N",
        "Donation",
        "1",
        "Donation",
        "-1",
        "$gross",
        ""
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Donation",
        "Virginia Dept of Taxation",
        "0.00",
        "N",
        "Sales Tax Payable",
        "3",
        "Non",
        "1",
        "0.00%",
        "AUTOSTAX",
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'paypal_to_main' )  {
    # Special Headers
    $stuff = '';

    my @transheaders = qw{!TRNS MEMO TRNSTYPE DATE ACCNT AMOUNT NAMEISTAXABLE};
    $stuff .= join("\t", @transheaders)."\n";

    my @splheaders = qw{!SPL MEMO TRNSTYPE DATE ACCNT AMOUNT TAXABLE SPLID};
    $stuff .= join("\t", @splheaders)."\n";

    $stuff .= "!ENDTRNS\n";

    $stuff .= join("\t", ( "TRNS",
        "Transferring PayPal Account to Main Account",
        "TRANSFER",
        "$date",
        "PayPal",
        "-$gross",
        "N",  # No taxes on bank transfers
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Transferring PayPal Account to Main Account",
        "TRANSFER",
        "$date",
        "Main Account",
        "$gross",
        "N",  # No taxes on bank transfers
        1,
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'main_to_paypal' )  {
    # Special Headers
    $stuff = '';

    my @transheaders = qw{!TRNS MEMO TRNSTYPE DATE ACCNT AMOUNT NAMEISTAXABLE};
    $stuff .= join("\t", @transheaders)."\n";

    my @splheaders = qw{!SPL MEMO TRNSTYPE DATE ACCNT AMOUNT TAXABLE SPLID};
    $stuff .= join("\t", @splheaders)."\n";

    $stuff .= "!ENDTRNS\n";

    $stuff .= join("\t", ( "TRNS",
        "Transferring Main Account to PayPal Account",
        "TRANSFER",
        "$date",
        "Main Account",
        "-$gross",
        "N",  # No taxes on bank transfers
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Transferring Main Account to PayPal Account",
        "TRANSFER",
        "$date",
        "PayPal",
        "$gross",
        "N",  # No taxes on bank transfers
        1,
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'postage_main' )  {
    # This is used for the case where the LLG spends money through
    # Bob, like Bob uses a credit card, or takes LLG money out later
    # to make up for money he spent.  As such, we *have paid out the
    # money*.  Since Bob's balance records money we *owe*, these
    # transactions do not affect it, since we don't owe him
    # anything, having already paid.  If you wanted something like
    # this that *did* affect his balance (i.e. he pays for something
    # and we *haven't* paid him back yet, or paying out his
    # balance), well, you should probably do that by hand, but try
    # "Accounts Receivable" as the account if you want to do it as a
    # check like this.

    # Special Headers
    $stuff = '';

    my @transheaders = qw{!TRNS MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT NAMEISTAXABLE};
    $stuff = join("\t", @transheaders)."\n";

    my @splheaders = qw{!SPL MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT TAXABLE SPLID};
    $stuff .= join("\t", @splheaders)."\n";

    $stuff .= "!ENDTRNS\n";

    $stuff .= join("\t", ( "TRNS",
        "Postage Payment By Bob",
        "CHECK",
        "$date",
        "$date",
        "Main Account",
        "LeChevalier, Robert",
        "Lump Payment",
        "-$gross",
        "N",  # No taxes on postage
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Postage Payment By Bob",
        "CHECK",
        "$date",
        "$date",
        "Postage and Delivery",
        "LeChevalier, Robert",
        "Lump Payment",
        "$gross",
        "N",  # No taxes on postage
        "1",
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'corp_main' )  {
    # See postage_main for notes on why this doesn't affect bob's
    # balance

    # Special Headers
    $stuff = '';

    my @transheaders = qw{!TRNS MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT NAMEISTAXABLE};
    $stuff = join("\t", @transheaders)."\n";

    my @splheaders = qw{!SPL MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT TAXABLE SPLID};
    $stuff .= join("\t", @splheaders)."\n";

    $stuff .= "!ENDTRNS\n";

    $stuff .= join("\t", ( "TRNS",
        "Corporate Filing Payment By Bob",
        "CHECK",
        "$date",
        "$date",
        "Main Account",
        "LeChevalier, Robert",
        "Lump Payment",
        "-$gross",
        "N",  # No taxes on postage
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Corporate Filing Payment By Bob",
        "CHECK",
        "$date",
        "$date",
        "Licenses and Permits",
        "LeChevalier, Robert",
        "Lump Payment",
        "$gross",
        "N",  # No taxes on postage
        "1",
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'direct_paypal' )  {
    # Special Headers
    $stuff = '';

    my @transheaders = qw{!TRNS MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT NAMEISTAXABLE};
    $stuff = join("\t", @transheaders)."\n";

    my @splheaders = qw{!SPL MEMO TRNSTYPE DATE DUEDATE ACCNT NAME CLASS AMOUNT TAXABLE SPLID};
    $stuff .= join("\t", @splheaders)."\n";

    $stuff .= "!ENDTRNS\n";

    $stuff .= join("\t", ( "TRNS",
        "Special-Case One-Time Payment",
        "CHECK",
        "$date",
        "$date",
        "PayPal",
        "$name_swapped",
        "Lump Payment",
        "-$gross",
        "N",  # No taxes on paypal transfers
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "Special-Case One-Time Payment",
        "CHECK",
        "$date",
        "$date",
        "Miscellaneous",
        "$name_swapped",
        "Lump Payment",
        "$gross",
        "N",  # No taxes on paypal transfers
        "1",
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } elsif( $type eq 'cll' )  {
    # Grab the quantity out of the subject
    #
    # 'Subject' => '1 copy(s) of The Complete Lojban Language, Priority Mail To Everywhere Else',
    my $quant = $data->{'Subject'};
    $quant =~ s/ .*//;

    # Calculate the book sales amount
    my $sale_amount = $quant * $CLL_PRICE;

    # Calculate the postage
    my $postage = $gross - $sale_amount;

    # Pull the tax out of the postage, essentially giving a discount
    # on the postage in the amount of the tax.  THIS IS PROBABLY
    # CHEATING, but I don't think anyone's likely to care
    my $tax_amount=0;
    if( $taxable eq 'Y' ) {
      $tax_amount = $quant * $CLL_PRICE * 0.05;
      $postage = $postage - $tax_amount;
    }

    $stuff .= join("\t", ( "TRNS",
        "CLL Purchase",
        "$name_swapped",
        "$gross",
        "$taxable",
        "PayPal",
        "$firstname",
        "$lastname",
        "$date",
        "BookSales",
        "CASH SALE",
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "CLL Purchase",
        "$name_swapped",
        "-$sale_amount",
        "$taxable",
        "Book Sales",
        "1",
        "Book1",
        "-$quant",
        "$CLL_PRICE",
        ""
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "CLL Purchase Postage",
        "",
        "-$postage",
        "N",  # Shipping/handling not taxable
        "Miscellaneous Income",
        "2",
        "Postage - Income",
        "-1",
        "$postage",
        ""
      ))."\n";

    $stuff .= join("\t", ( "SPL",
        "CLL Purchase Tax",
        "Virginia Dept of Taxation",
        "-$tax_amount",
        "N",  # sales tax not taxable
        "Sales Tax Payable",
        "3",
        $taxable eq 'Y' ? "vasalestax" : "Out of State",
        "-1",
        $taxable eq 'Y' ? "5.00%" : "0.00%",
        "AUTOSTAX",
      ))."\n";

    $stuff .= "ENDTRNS\n";
  } else {
    die "UNKNOWN TRANSACTION TYPE IN qb_trans!\n";
  };

  my $pp_fee = $data->{'Fee'};
  if( $pp_fee ) {
    $pp_fee =~ s/^ *-*//;

    if( $pp_fee > 0 ) {
      $stuff .= qb_bill( $date, $pp_fee, "PayPal", "Miscellaneous", "PayPal", "PayPal Charges" );
    }
  }

  return $stuff;

};

sub qb_customer {
  my ($data, $taxable) = @_;

  my @headers = qw{!CUST NAME FIRSTNAME LASTNAME TAXABLE CONT1 EMAIL BADDR1 BADDR2 BADDR3 BADDR4 BADDR5 SADDR1 SADDR2 SADDR3 SADDR4 SADDR5};

  my $stuff = join("\t", @headers)."\n";

  my $name=$data->{'Name'};
  my $email=$data->{'From Email Address'};
  my $address=$data->{'Shipping Address'};

  # Comma-splice the name
  my $name_swapped = $name;
  $name_swapped =~ s/\s*([^\s]*)\s+(.*)/$2, $1/;
  my $firstname = $1;
  my $lastname = $2;

  # Donations, for example, have no address
  my @address = ('', '', '', '', '');

  if( $address ) {
    # Take the name out of the address
    $address =~ s/^ *$name\,\s*//;

    # Split the address up.
    @address = split( /,\s*/, $address, 5 );
    # print "$name, $email, ".join( ' : ', @address ) . "\n";

    for( my $i=0; $i <= 4; $i++ )
    {
      if( ! defined $address[$i] || ! exists $address[$i] )
      {
        $address[$i] = '';
      }
    }
  }

  my @bits = ( "CUST",
    "$name_swapped", "$firstname", "$lastname",
    "$taxable",
    "$name",
    "$email",
    "$address[0]", "$address[1]", "$address[2]", "$address[3]", "$address[4]",
    "$address[0]", "$address[1]", "$address[2]", "$address[3]", "$address[4]",
  );

  $stuff .= join("\t", @bits)."\n";

  return $stuff;
};

sub usage {
  print "First argument: quarter id, like 2012Q1.  Second argument: the PayPal CSV file.  Third argument: they Wells Fargo CSV file.\n";
  exit(1);
};

sub prompt_enter {
  my ($prompt) = @_;

  print $prompt;
  <STDIN>;
};

sub prompt_confirm {
  my ($prompt, $data) = @_;

  while( 1 ) {
    print $prompt;
    my $line = <STDIN>;

    if( $line =~ m/^ *y(es)? *$/i ) {
      return 1;
    }
    if( $line =~ m/^ *n(o)? *$/i ) {
      return 0;
    }
    if( $line =~ m/^ *c(omplete)? *$/i ) {
      print Dumper($data);
    }
  }
};
#**************************************
# END Declarations
#**************************************

my $quarter = $ARGV[0];

my $paypal_filename = $ARGV[1];

my $wf_filename = $ARGV[2];

if( ! defined $paypal_filename || ! -f $paypal_filename ) {
  usage();
}

if( ! defined $wf_filename || ! -f $wf_filename ) {
  usage();
}

my $csv = Text::CSV->new ( { binary => 1, allow_whitespace => 1 } ) or die "Cannot use CSV: ".Text::CSV->error_diag ();

my ($accepted, $qb, @failed, @header);

#**************************************
# PAYPAL SECTION
#**************************************
my $paypal_raw = read_file( $paypal_filename, { binmode => ':raw' } )  or die "Trying to open $paypal_filename: $!";

$paypal_raw =~ s/[^[:ascii:]]//g;
$paypal_raw =~ s/"0/" 0/g; # Text::CSV includes '",0' in preceding column

my @pp_lines=split(/[\r\n]+/,$paypal_raw);

my $header = shift @pp_lines;

$csv->parse($header);
@header = $csv->fields();

# print "header: ".Dumper(\@header)."\n";

PPLOOP: foreach my $line (@pp_lines) {
  $csv->parse($line);
  my @lfields = $csv->fields();
  map { s/^ 0/0/ } @lfields;
  my %line = zip @header, @lfields;

  # Remove stuff we probably don't care about, even in theory.
  delete $line{''};
  delete $line{'Option 1 Value'};
  delete $line{'Auction Site'};
  delete $line{'Receipt ID'};
  delete $line{'Closing Date'};
  delete $line{'Custom Number'};
  delete $line{'Insurance Amount'};
  # Personally entered data; should be presented!
  # Ex: 'Note' => 'For more details (if needed) please email me on alklazema@gmail.com.',
  #delete $line{'Note'};
  delete $line{'Subscription Number'};
  delete $line{'Reference Txn ID'};
  delete $line{'Option 2 Value'};
  delete $line{'Item URL'};
  delete $line{'Invoice Number'};
  delete $line{'Option 2 Name'};
  delete $line{'Option 1 Name'};
  # CLL is: 'Item ID' => 'ISBN 0-9660283-0-9',
  #delete $line{'Item ID'};
  delete $line{'Transaction ID'};
  delete $line{'Receipt ID'};
  delete $line{'Closing Date'};
  delete $line{'Custom Number'};
  delete $line{'Insurance Amount'};
  delete $line{'Sales Tax'};

  if( $line{'Note'} ) {
    say "\n\n**************** The following entry has a special note, as follows: ".$line{'Note'};
  }

  for my $guess (@pp_alternatives) {
    my $interpretation = $guess->(\%line);
    if (defined($interpretation)) {
      my ($type, $partial, $qbrecord) = @$interpretation;

      my $prompt="\n\nI think that this PAYPAL entry: \n";
      $prompt .= Dumper($partial);
      $prompt .= "is $type; do you agree? [y/n/c] ";

      if (prompt_confirm($prompt, \%line)) {
        $accepted .= $prompt;
        $qb .= $qbrecord;
        next PPLOOP;
      }
    }
  }

  print "WARNING: unhandled block.\n";
  print "line: ".Dumper(\$line)."\n";
  print "%line: ".Dumper(\%line)."\n";

  prompt_enter("Hit enter to continue.");
  push @failed, \%line;
}

#**************************************
# WELLS FARGO SECTION
#**************************************
my $wf_raw = read_file( $wf_filename, { binmode => ':raw' } )  or die "Trying to open $wf_filename: $!";

$wf_raw =~ s/[^[:ascii:]]//g;
$wf_raw =~ s/"0/" 0/g;

my @wf_lines=split(/[\r\n]+/,$wf_raw);

@header = ('Date', 'Gross', 'Crap1', 'Crap2', 'Description');

PPLOOP: foreach my $line (@wf_lines) {
  $csv->parse($line);
  my @lfields = $csv->fields();
  map { s/^ 0/0/ } @lfields;
  my %line = zip @header, @lfields;

  # Remove stuff we probably don't care about, even in theory.
  delete $line{'Crap1'};
  delete $line{'Crap2'};

  for my $guess (@wf_alternatives) {
    my $interpretation = $guess->(\%line);
    if (defined($interpretation)) {
      my ($type, $partial, $qbrecord) = @$interpretation;

      my $prompt="\n\nI think that this WELLS FARGO entry: \n";
      $prompt .= Dumper($partial);
      $prompt .= "is $type; do you agree? [y/n/c] ";

      if (prompt_confirm($prompt, \%line)) {
        $accepted .= $prompt;
        $qb .= $qbrecord;
        next PPLOOP;
      }
    }
  }

  print "WARNING: unhandled block.\n";
  print "line: ".Dumper(\$line)."\n";
  print "%line: ".Dumper(\%line)."\n";

  prompt_enter("Hit enter to continue.");
  push @failed, \%line;
}

write_file( "/tmp/$quarter.accepted.txt", $accepted );
write_file( "/tmp/$quarter.failed.txt", Dumper(@failed) );
write_file( "/tmp/$quarter.qb.iif", $qb );

say "OK, so the data is in the following files:

/tmp/$quarter.accepted.txt has a review of everything that succeded.  File size: ".qx{ls -sh /tmp/$quarter.accepted.txt}."

/tmp/$quarter.failed.txt has everything that failed, in complete detail.  File size: ".qx{ls -sh /tmp/$quarter.failed.txt}."

/tmp/$quarter.qb.iif has the QuickBooks 2002 import file.  File size: ".qx{ls -sh /tmp/$quarter.qb.iif}."

When you're done, please run:

rm /tmp/$quarter*

for security.

";
