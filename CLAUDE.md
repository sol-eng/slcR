# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`slcR` is a native R package that provides an interface to Altair SLC (Statistical Language Compiler). It implements the complete ORB (Object Request Broker) protocol and WPS Link interface in pure R, eliminating Python dependencies. The package enables R users to execute SAS code, manage libraries and datasets, and interact with SLC sessions.

## Development Commands

### Installation and Loading
```r
# Install package from source
devtools::install()

# Load the package
library(slcR)

# Quick test (from run.R)
devtools::install()
library(slcR)
x <- Slc$new()
```

### Testing
```r
# Run all tests
devtools::test()

# Run package check (includes tests, examples, documentation)
devtools::check()
```

### Documentation
```r
# Generate documentation from roxygen2 comments
devtools::document()
```

## Architecture

The codebase has a three-layer architecture, from low-level to high-level:

### Layer 1: ORB Layer (Binary Communication Protocol)

**Core Components:**
- [R/cdr_buffer.R](R/cdr_buffer.R) - `CdrBuffer`: Binary serialization/deserialization using CDR (Common Data Representation) format
- [R/protocol.R](R/protocol.R) - Message protocol classes: `MessageHeader`, `RequestHeader`, `ReplyHeader`
- [R/connection.R](R/connection.R) - `NamedPipeConnection`, `ProcessConnection`: IPC with SLC via named pipes (FIFOs on Unix)
- [R/orb.R](R/orb.R) - `Orb`: Main ORB implementation managing message passing, request/reply pattern, buffer pooling
- [R/object.R](R/object.R) - `OrbObject`: Base class for remote object references, `ObjectAdapter`: servant object management
- [R/exceptions.R](R/exceptions.R) - Exception hierarchy for ORB and application errors

**How ORB Communication Works:**

1. **Process Startup:** Creates temporary named pipes (FIFOs), starts `wpslinks` binary with `-namedpipe` flag, performs handshake
2. **Message Flow:** Client creates request buffer → writes operation + arguments → sends via pipe → SLC receives and dispatches → sends reply → client parses reply
3. **Binary Protocol:** Messages use CDR encoding with:
   - Message Header (12 bytes): eye catcher (0x57524D49), protocol version, message type, flags, length
   - Request Header: request ID, target object ID, operation name, flags
   - Reply Header (5 bytes): request ID, reply status (NO_EXCEPTION, USER_EXCEPTION, SYSTEM_EXCEPTION)

### Layer 2: WPS Link Layer (SLC Interface Stubs)

[R/wpslink.R](R/wpslink.R) contains stub classes that wrap ORB calls to SLC server objects:
- `WpsServer`: Server object factory (creates sessions, gets DNS/OS info)
- `WpsSession`: Main session interface (submit code, manage libraries, macro variables, get log/listing)
- `WpsLibref`: Library reference (list/open/create datasets)
- `WpsDataset`: Dataset interface (get nobs/nvars, close)
- `WpsLogFile`, `WpsListingFile`: Log and listing file access

**Pattern for WPS Link Methods:**
```r
method_name = function(args...) {
  in_buf <- NULL
  tryCatch({
    out_buf <- self$request("operationName")
    out_buf$write_type(arg1)
    out_buf$write_type(arg2)
    in_buf <- self$invoke(out_buf)
    result <- in_buf$read_type()
    result
  }, finally = {
    if (!is.null(in_buf)) {
      self$release_buf(in_buf)
    }
  })
}
```

### Layer 3: High-Level API

User-facing R6 classes providing idiomatic R interface:
- [R/slc_new.R](R/slc_new.R) - `Slc`: Main connection class with process management, session initialization, code submission
- [R/library.R](R/library.R) - `Library`: High-level library operations (list datasets, open/create datasets)
- [R/dataset.R](R/dataset.R) - `Dataset`: Dataset operations (get dimensions, convert to data frame)

## Quarto / knitr Integration

The package ships a Quarto extension (`inst/quarto-ext/slcr/`) and registers a knitr engine (`R/engine.R`) that runs `{slc}` code chunks.

### Required document setup

Every Quarto document using `{slc}` chunks needs **both** of the following — omitting either is a common source of silent failures:

1. **`engine: knitr`** in the YAML front matter. Without it Quarto selects the Jupyter engine and the `slc` knitr engine is never registered — chunks appear as literal fenced-code text in the output.

2. **A hidden R setup chunk that loads slcR.** This fires `.onLoad`, which calls `knitr::knit_engines$set(slc = slc_engine)`. Without it knitr emits `Warning: Unknown language engine 'slc'` and skips all SLC chunks.

Minimal correct document header:

```yaml
---
title: "My Report"
format:
  html:
    code-fold: false
filters:
  - slcr
engine: knitr
---
```

````
```{r setup, include=FALSE}
library(slcR)
```
````

### Engine chunk options

| Option | Default | Description |
|--------|---------|-------------|
| `eval` | `TRUE` | Execute the code |
| `echo` | `TRUE` | Show the source code |
| `new_session` | `FALSE` | Start a fresh isolated SLC process for this chunk; `FALSE` reuses the shared session |
| `input_data` | — | Comma-separated R data frame name(s) to transfer into SLC |
| `output_data` | — | Comma-separated SLC dataset name(s) to pull back into R |
| `show_listing` | `TRUE` | Show SAS listing (LST) output below the log (only used when no HTML table output is produced) |
| `output_files` | — | Override: comma-separated paths to embed. Usually not needed — figures are auto-discovered |
| `fig-cap` | — | Caption(s) for figures. Single string applied to all; list/vector assigns one per figure. **Must be set via `#\|` inside the chunk body — never in the inline header** (see below) |

### Shared session (default behaviour)

All `{slc}` chunks in a document share a single SLC process by default (`new_session = FALSE`). WORK datasets, macro variables, and any other session state created in one chunk are visible to all subsequent chunks. The shared process is started on first use and shut down automatically when the document finishes rendering via a knitr `document` hook registered in `R/session.R`.

To run a chunk in an isolated process (one that cannot see state from other chunks), set `new_session = TRUE` on that chunk. To isolate the entire document, add to a setup chunk:

```r
knitr::opts_chunk$set(new_session = TRUE)
```

The internal helpers `get_shared_connection()` and `shutdown_shared_connection()` in `R/session.R` manage the cached `Slc` object stored in `.slcr_env` (defined in `R/zzz.R`).

### How table output works

Before running user code the engine opens an `ods tagsets.htmlcss` destination to a temp file. After execution it closes the destination and reads the file. If the body contains `<TABLE>` elements the content is emitted as a raw HTML block wrapped in a green collapsible `<details class="slc-table-collapsible">` ("📋 SLC Table Output"), open by default. This happens automatically for any chunk that contains tabular procedures (`proc print`, `proc tabulate`, `proc means`, etc.) — no chunk option is needed.

The engine skips opening `ods tagsets.htmlcss` for chunks that already contain `ods html` in their code (i.e. figure chunks), because two simultaneous ODS HTML-family destinations conflict.

**Note:** `ods html` (standard) produces a JS-driven shell with an empty `<BODY>` in SLC and is not suitable for embedding tables. `ods tagsets.htmlcss` writes real static HTML table markup and is used instead.

### How listing output works

Plain-text listing output (from `connection$get_listing_output()`) is used as a fallback when no HTML table output was produced by the chunk — i.e. it applies to chunks that neither produced tabular ODS output nor managed their own ODS HTML destination. When non-empty and `show_listing` is not `FALSE`, the text is appended wrapped in HTML sentinel comments (`<!-- slc-listing-start -->` / `<!-- slc-listing-end -->`). The JavaScript in `slc-resources.html` detects those sentinels and renders the listing in a separate blue-tinted collapsible block ("📋 SLC Listing").

### How image output works

Figures are **auto-discovered** — no `output_files` is needed. The engine scans only log lines produced by the current chunk (using a before/after line-count diff on the cumulative session log) for `NOTE: Successfully written image <path>` lines.

**SLC-specific behavior:** SLC's `ods html gpath=` parameter is silently ignored; images are always written to `<WORK>/ODS LISTING images/Ixxxxxxx.png` regardless. The engine queries the SLC WORK path via `%sysfunc(getoption(work))` once per session (cached in `.slcr_env$slc_work_path`) and resolves relative log paths against it.

The standard pattern for figure chunks:

````
```{slc label="my-figure"}
#| fig.cap: "My figure caption"
ods html body='' gpath="&slcr_gpath" style=htmlblue;
ods graphics / width=700px height=500px;
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
ods html close;
```
````

**Important:** `fig-cap` must always be specified as a `#|` YAML option inside the chunk body, never in the inline chunk header (e.g. `` ```{slc fig-cap="..."} ``). knitr parses inline options with `alist()`, which treats the hyphen in `fig-cap` as a minus operator and throws a parse error. `fig.cap` (with a dot) also works as the `#|` key and is equivalent.

`&slcr_gpath` is set as a SAS macro variable by the engine before each chunk runs (pointing to a per-chunk temp directory) so user code can reference it. In practice SLC ignores it for image placement, but including it is harmless and documents intent.

Use `output_files` only when auto-discovery misses a file at a fully custom path:

````
```{slc output_files="/custom/path/myplot.png"}
ods html body='/custom/path/myplot.png';
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
ods html close;
```
````

`embed_output_files()` is retained as a backward-compatible shim but is deprecated; it now delegates to `render_slc_figures()` internally.

### Extension installation

```r
# Install the Quarto extension into the current project
slcR::install_slc_extension()
```

The extension reads `_extensions/slcr/slc-resources.html` at render time via the Lua filter. Both that file and `inst/resources/slc-resources.html` (used by `slc_quarto_resources()`) must be kept in sync when modifying CSS/JS.

## Key Implementation Details

### Process Management
- Uses `processx` package to start SLC process with `wpslinks -namedpipe`
- Reads pipe names from process stdout ("Reading from pipe..." / "Writing to pipe...")
- Maintains process handle for lifetime checking and cleanup

### Named Pipes
- **Unix/Linux:** Uses FIFO named pipes via R's `file()` connections with `open="r+b"` mode
- **Windows:** Not yet implemented (requires Windows named pipe API)
- Pipes are opened non-blocking, but reads/writes are synchronous

### Synchronous vs Asynchronous
The R implementation is **synchronous** (blocks waiting for replies) while the Python reference implementation uses threads. The R `Orb$wait_for_reply()` polls for incoming messages with sleep intervals.

### Buffer Management
`BufferPool` class reuses `CdrBuffer` instances to reduce allocation overhead. Always use `try/finally` to ensure buffers are released back to pool.

### Dataset I/O Workaround
Direct binary dataset I/O is not fully implemented. Use PROC IMPORT/EXPORT with temporary CSV/Parquet files:
```r
# Export dataset to R
temp_file <- tempfile(fileext = ".csv")
slc$submit(sprintf("proc export data=work.mydata outfile='%s' dbms=csv replace; run;", temp_file))
df <- readr::read_csv(temp_file)

# Import R data frame to SLC
readr::write_csv(df, temp_file)
slc$submit(sprintf("proc import datafile='%s' out=work.newdata dbms=csv replace; run;", temp_file))
```

## Environment Requirements

### SLC Binary Location
The package looks for SLC binaries in this order:
1. `$WPSHOME/bin/wpslinks` (or `$WPSHOME/MacOS/wpslinks` on macOS)
2. Relative to package installation: `../../bin/wpslinks`
3. Default search paths for platform

Set `WPSHOME` environment variable if needed:
```r
Sys.setenv(WPSHOME = "/opt/altair/slc/2026")
```

### Platform Support
- **Linux/Unix:** ✅ Full support
- **macOS:** ✅ Should work (same FIFO mechanism)
- **Windows:** ❌ Requires Windows named pipes implementation

## Adding New Operations

To add a new WPS Link operation:

1. Add method to appropriate stub class in [R/wpslink.R](R/wpslink.R)
2. Follow the standard pattern: `request()` → write args → `invoke()` → read result → release buffer
3. Add high-level wrapper in [R/slc_new.R](R/slc_new.R), [R/library.R](R/library.R), or [R/dataset.R](R/dataset.R)

Example:
```r
# In WpsSession (R/wpslink.R)
get_option = function(name) {
  in_buf <- NULL
  tryCatch({
    out_buf <- self$request("getOption")
    out_buf$write_string(name)
    in_buf <- self$invoke(out_buf)
    in_buf$read_string()
  }, finally = {
    if (!is.null(in_buf)) {
      self$release_buf(in_buf)
    }
  })
}

# In Slc (R/slc_new.R)
get_option = function(name) {
  private$session_obj$get_option(name)
}
```

## Reference Implementation

The [py-orb/](py-orb/), [py-slc/](py-slc/), and [py-wpslink/](py-wpslink/) directories contain the original Python implementation that this package was ported from. Refer to these for protocol details and method signatures when implementing new features.

## Common Issues

**"Could not find SLC binary"** - Set `WPSHOME` environment variable to SLC installation root

**"Failed to read expected number of bytes from pipe"** - Check process is alive (`slc$process$is_alive()`), check stderr (`slc$process$read_error()`), verify pipes exist

**"Timeout waiting for reply"** - Operation took too long, increase timeout in `Orb$wait_for_reply()`, or check SLC log for errors

**Process dies during startup** - Check stderr output from SLC process, verify SLC installation is valid, ensure proper permissions on temp directory for named pipes
