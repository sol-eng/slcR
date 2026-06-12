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

### Table output

Tabular procedures (`proc print`, `proc tabulate`, `proc means`, etc.) automatically produce formatted HTML tables — no special chunk options needed. The output appears in a green collapsible "📋 SLC Table Output" block, open by default:

```` markdown
```{slc}
proc print data=work.summary noobs;
run;
```
````

The engine uses `ods tagsets.htmlcss` internally to capture static HTML table markup. This is skipped for figure chunks (those containing `ods html`) to avoid destination conflicts.

### Listing output

Plain-text listing output is shown as a fallback when a chunk produces no HTML table output. Suppress it with `show_listing=FALSE`:

```` markdown
```{slc show_listing=FALSE}
proc means data=sashelp.class;
run;
```
````

### Image output

Figures are **auto-discovered** — ODS graphics are embedded automatically. The engine scans `NOTE: Successfully written image ...` lines from the SAS log (scoped to the current chunk's new log lines only) and resolves paths against the SLC WORK directory:

```` markdown
```{slc fig-cap="Height vs Weight"}
ods html body='' gpath="&slcr_gpath" style=htmlblue;
ods graphics / width=700px height=500px;
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
ods html close;
```
````

`&slcr_gpath` is a per-chunk SAS macro variable set by the engine. Note that SLC always writes images to its WORK temp directory regardless of `gpath=`; the engine resolves those paths automatically.

Use `output_files` only when auto-discovery misses a file at a fully custom path:

```` markdown
```{slc output_files="/custom/path/myplot.png"}
ods html body='/custom/path/myplot.png';
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