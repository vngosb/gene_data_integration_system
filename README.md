# Gene Data Integration 

## Description
This Perl script integrates gene data from Ensembl, NCBI, and UCSC Genome Browser into a SQLite database. It fetches gene-related details such as descriptions, chromosome coordinates, and exon information for a specified gene. The script also generates a PDF report summarizing the data.

---

## Features
- Fetches gene descriptions from **NCBI Entrez Gene**.
- Retrieves chromosome coordinates from the **Ensembl REST API**.
- Gathers exon information from the **UCSC Genome Browser**.
- Stores the data in a SQLite database.
- Exports the data into a PDF report.

---

## Prerequisites
Ensure the following Perl modules are installed:
- `LWP::UserAgent`
- `JSON`
- `XML::Simple`
- `DBI`
- `Try::Tiny`
- `PDF::API2`


## How to Use

Run the script:
perl script_name.pl
Enter a valid gene symbol (e.g., ABCG2) when prompted.
The script:
Fetches gene data from APIs.
Stores it in the SQLite database gene_data.db.
Generates a PDF report (GENENAME_gene_data.pdf).
SQLite Database Structure

The script creates the following tables:

ensembl: Stores chromosome coordinates.
CREATE TABLE IF NOT EXISTS ensembl (
    gene_symbol TEXT PRIMARY KEY, 
    chromosome TEXT, 
    start_position INTEGER, 
    end_position INTEGER
);
ncbi: Stores gene descriptions.
CREATE TABLE IF NOT EXISTS ncbi (
    gene_symbol TEXT PRIMARY KEY, 
    description TEXT
);
ucsc: Stores exon details and gene type.
CREATE TABLE IF NOT EXISTS ucsc (
    gene_symbol TEXT PRIMARY KEY, 
    exon_count INTEGER, 
    exon_sizes TEXT, 
    exon_starts TEXT, 
    gene_type TEXT
);

## Output

PDF Report containing:

Gene Symbol
Description
Chromosome
Start and End Positions
Exon Count, Sizes, and Starts
Gene Type

## Error Handling

The script validates user input for the gene symbol.
Errors during API calls are caught and logged using Try::Tiny.
Warnings are displayed for issues like:
Missing gene data.
Failed API responses.
