use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use XML::Simple;
use DBI;
use Try::Tiny;
use PDF::API2;

# Initialize resources
my $ua = LWP::UserAgent->new;
$ua->timeout(10);
my $json = JSON->new;
my $xml_parser = XML::Simple->new;

# SQLite database setup
my $dbh = DBI->connect("dbi:SQLite:dbname=gene_data.db", "", "", { RaiseError => 1, AutoCommit => 1 })
    or die "Failed to connect to database: $DBI::errstr";

# Create tables
$dbh->do("CREATE TABLE IF NOT EXISTS ensembl (gene_symbol TEXT PRIMARY KEY, chromosome TEXT, start_position INTEGER, end_position INTEGER)");
$dbh->do("CREATE TABLE IF NOT EXISTS ncbi (gene_symbol TEXT PRIMARY KEY, description TEXT)");
$dbh->do("CREATE TABLE IF NOT EXISTS ucsc (gene_symbol TEXT PRIMARY KEY, exon_count INTEGER, exon_sizes TEXT, exon_starts TEXT, gene_type TEXT)");

# Main program to accept a gene name with validation
print "Enter the gene name: ";
my $gene_symbol = <STDIN>;
chomp $gene_symbol;

if (!$gene_symbol || $gene_symbol !~ /^\w+$/) {
    die "Invalid input. Please provide a valid gene name (example: ABCG2).\n";
}

# Insert data into tables
sub insert_ensembl_data {
    my ($gene_symbol, $chromosome, $start, $end) = @_;
    $dbh->do("INSERT OR REPLACE INTO ensembl (gene_symbol, chromosome, start_position, end_position) VALUES (?, ?, ?, ?)",
        undef, $gene_symbol, $chromosome, $start, $end);
}

sub insert_ncbi_data {
    my ($gene_symbol, $description) = @_;
    $dbh->do("INSERT OR REPLACE INTO ncbi (gene_symbol, description) VALUES (?, ?)", undef, $gene_symbol, $description);
}

sub insert_ucsc_data {
    my ($gene_symbol, $exon_count, $exon_sizes, $exon_starts, $gene_type) = @_;
    $dbh->do("INSERT OR REPLACE INTO ucsc (gene_symbol, exon_count, exon_sizes, exon_starts, gene_type) VALUES (?, ?, ?, ?, ?)",
        undef, $gene_symbol, $exon_count, $exon_sizes, $exon_starts, $gene_type);
}

# NCBI subroutine
sub fetch_ncbi_description {
    my ($gene_symbol) = @_;
    my $description = "N/A";

    my $esearch_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=gene&term=$gene_symbol%5BGene%20Name%5D+AND+human%5BOrganism%5D&retmode=xml";
    my $efetch_base_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=gene&retmode=xml&id=";

    try {
        my $esearch_response = $ua->get($esearch_url);
        die "Failed to fetch gene ID: ", $esearch_response->status_line unless $esearch_response->is_success;

        my $esearch_data = $xml_parser->XMLin($esearch_response->content);
        my $gene_id = $esearch_data->{IdList}->{Id} || die "No gene ID found for $gene_symbol.\n";

        my $efetch_url = $efetch_base_url . $gene_id;
        my $efetch_response = $ua->get($efetch_url);
        die "Failed to fetch gene data: ", $efetch_response->status_line unless $efetch_response->is_success;

        my $efetch_data = $xml_parser->XMLin($efetch_response->content);
        my $gene_info = $efetch_data->{Entrezgene}->{Entrezgene_gene};
        $description = $gene_info->{"Gene-ref"}->{"Gene-ref_desc"} if $gene_info && $gene_info->{"Gene-ref"} && defined $gene_info->{"Gene-ref"}->{"Gene-ref_desc"};
    } catch {
        warn "Error fetching NCBI data for $gene_symbol: $_\n";
    };

    return $description;
}

# Ensembl subroutine
sub fetch_ensembl_coordinates {
    my ($gene_symbol) = @_;
    my ($chromosome, $start, $end) = ("N/A", "N/A", "N/A");

    my $species = "human";
    my $url = "https://rest.ensembl.org/lookup/symbol/$species/$gene_symbol?content-type=application/json";

    try {
        my $response = $ua->get($url);
        die "Failed to fetch data from Ensembl: ", $response->status_line unless $response->is_success;

        my $gene_data = $json->decode($response->decoded_content);
        $chromosome = $gene_data->{seq_region_name};
        $start = $gene_data->{start};
        $end = $gene_data->{end};
    } catch {
        warn "Error fetching Ensembl data for $gene_symbol: $_\n";
    };

    return ($chromosome, $start, $end);
}

# UCSC subroutine
sub fetch_ucsc_exon_info {
    my ($chromosome, $start, $end, $gene_symbol) = @_;
    my ($exon_count, $exon_sizes, $exon_starts, $gene_type) = ("N/A", "N/A", "N/A", "N/A");

    return ($exon_count, $exon_sizes, $exon_starts, $gene_type) if $chromosome eq "N/A";

    my $assembly = 'hg38';
    my $url = "https://api.genome.ucsc.edu/getData/track?genome=$assembly&track=knownGene&chrom=$chromosome&start=$start&end=$end";

    try {
        my $response = $ua->get($url);
        die "Failed to get data from UCSC: ", $response->status_line unless $response->is_success;

        my $data = $json->decode($response->decoded_content);
        foreach my $transcript (@{$data->{knownGene}}) {
            if ($transcript->{geneName} eq $gene_symbol) {
                $exon_count = $transcript->{blockCount};

                # Join exon_sizes and exon_starts into comma-separated strings, but remove any trailing commas
                $exon_sizes = ref $transcript->{blockSizes} eq 'ARRAY' ? join(",", @{$transcript->{blockSizes}}) : $transcript->{blockSizes};
                $exon_starts = ref $transcript->{chromStarts} eq 'ARRAY' ? join(",", @{$transcript->{chromStarts}}) : $transcript->{chromStarts};

                # Remove trailing commas if any
                $exon_sizes =~ s/,$//;
                $exon_starts =~ s/,$//;

                $gene_type = $transcript->{geneType};
                last;
            }
        }
    } catch {
        warn "Error fetching UCSC data for $gene_symbol: $_\n";
    };

    return ($exon_count, $exon_sizes, $exon_starts, $gene_type);
}

# Subroutine for PDF export
sub export_to_pdf {
    my ($gene_symbol, $sth) = @_;

    # Create a valid filename by replacing non-alphanumeric characters in the gene name
    my $valid_gene_name = $gene_symbol;
    $valid_gene_name =~ s/[^a-zA-Z0-9]//g;  # Remove any non-alphanumeric characters

    # Generate the PDF filename dynamically based on the gene name
    my $pdf_filename = "$valid_gene_name\_gene_data.pdf";

    # Create a new PDF
    my $pdf = PDF::API2->new();
    my $page = $pdf->page();
    $page->mediabox('A4');

    # Add a font
    my $font = $pdf->corefont('Helvetica');

    # Set up text for PDF
    my $text = $page->text();
    $text->font($font, 12);
    $text->translate(50, 800);  # Starting position for text

    my $y_position = 800;  # Starting Y position for the first line

    while (my $row = $sth->fetchrow_hashref) {
        $text->translate(50, $y_position);  # Set the Y position for each line
        $text->text("Gene Symbol: $row->{gene_symbol}");
        $y_position -= 14;  # Move down for the next line

        $text->translate(50, $y_position);
        $text->text("Description: $row->{description}");
        $y_position -= 14;

        $text->translate(50, $y_position);
        $text->text("Chromosome: $row->{chromosome}");
        $y_position -= 14;

        $text->translate(50, $y_position);
        $text->text("Start Position: $row->{start_position}");
        $y_position -= 14;

        $text->translate(50, $y_position);
        $text->text("End Position: $row->{end_position}");
        $y_position -= 14;

        $text->translate(50, $y_position);
        $text->text("Exon Count: $row->{exon_count}");
        $y_position -= 14;

        $text->translate(50, $y_position);
        $text->text("Exon Sizes: $row->{exon_sizes}");
        $y_position -= 14;

        # Split Exon Starts into multiple lines if necessary
        my $exon_starts = $row->{exon_starts};
        my $max_line_length = 100;  # Maximum characters per line
        my @lines = unpack "(A$max_line_length)*", $exon_starts;  # Split into lines of max length

        foreach my $line (@lines) {
            $text->translate(50, $y_position);
            $text->text("Exon Starts: $line");
            $y_position -= 14;
        }

        $text->translate(50, $y_position);
        $text->text("Gene Type: $row->{gene_type}");
        $y_position -= 20;  # Add extra space after each record
    }

    # Save PDF
    $pdf->saveas($pdf_filename);

    print "Data has been exported to $pdf_filename.\n";
}


# Fetch data
my $description = fetch_ncbi_description($gene_symbol);
insert_ncbi_data($gene_symbol, $description);

my ($chromosome, $start, $end) = fetch_ensembl_coordinates($gene_symbol);
insert_ensembl_data($gene_symbol, $chromosome, $start, $end);

my ($exon_count, $exon_sizes, $exon_starts, $gene_type) = fetch_ucsc_exon_info($chromosome, $start, $end, $gene_symbol);
insert_ucsc_data($gene_symbol, $exon_count, $exon_sizes, $exon_starts, $gene_type);

# Retrieve and print data using SQL JOIN
my $sth = $dbh->prepare("
    SELECT ncbi.gene_symbol, ncbi.description, ensembl.chromosome, ensembl.start_position, ensembl.end_position, 
           ucsc.exon_count, ucsc.exon_sizes, ucsc.exon_starts, ucsc.gene_type
    FROM ncbi
    JOIN ensembl ON ncbi.gene_symbol = ensembl.gene_symbol
    JOIN ucsc ON ncbi.gene_symbol = ucsc.gene_symbol
    WHERE ncbi.gene_symbol = ?
");
$sth->execute($gene_symbol);

# Call the export_to_pdf subroutine
export_to_pdf($gene_symbol, $sth);
