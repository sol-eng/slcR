# slcR

R interface to Altair SLC (Statistical Language Compiler).

## Installation

You can install the development version of slcR from GitHub with:

``` r
# install.packages("devtools")
devtools::install_github("sol-eng/slcr")
```

## Example

``` r
library(slcR)

# Create SLC connection
slc <- Slc$new()

# Get the WORK library
work_lib <- slc$get_library("WORK")

# Submit SAS code
slc$submit("data test; x = 1; run;")

# Retrieve log and listing output
cat(slc$get_log())
cat(slc$get_listing_output())

# Clean up
slc$shutdown()
```

## Quarto Usage

### Setup

Install the Quarto extension into your project once:

``` r
slcR::install_slc_extension()
```

Add the filter to your document YAML front matter:

``` yaml
---
title: "My SAS Analysis"
filters:
  - slcr
---
```

### Running SAS code

Basic chunk — shows the log in a collapsible "📊 SLC Output" block:

```` markdown
```{slc}
proc print data=sashelp.class(obs=5);
run;
```
````

### Shared session across chunks

All `{slc}` chunks in a document share a single SLC process by default. Datasets and macro variables created in one chunk are available in all subsequent chunks — no need to pass data back and forth through R:

```` markdown
```{slc}
data work.scores;
  input name $ score;
  datalines;
Alice 92
Bob 85
;
run;
```

```{slc}
/* work.scores from the previous chunk is still in scope */
proc means data=work.scores mean;
  var score;
run;
```
````

The shared process is shut down automatically when the document finishes rendering. To run a specific chunk in an isolated process (one that cannot see state from other chunks), set `new_session = TRUE` on that chunk.

### Listing output

When SAS procedures produce listing output (PROC PRINT, PROC MEANS, etc.) it appears automatically in a separate blue-tinted "📋 SLC Listing" block. Suppress it with `show_listing=FALSE`:

```` markdown
```{slc show_listing=FALSE}
proc means data=sashelp.class;
run;
```
````

### Image output

For graphics written to disk by SLC code (e.g. via ODS), pass the file path(s) with `output_files` and they will be embedded inline:

```` markdown
```{slc output_files="myplot.png"}
ods html body='myplot.png' style=htmlblue;
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
ods html close;
```
````

### Data exchange

Transfer R data frames into SLC and retrieve SLC datasets back into R:

```` markdown
```{slc input_data="my_df" output_data="results"}
proc means data=work.my_df noprint;
  output out=work.results mean= / autoname;
run;
```
````