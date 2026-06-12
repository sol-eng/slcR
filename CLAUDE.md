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

### Engine chunk options

| Option | Default | Description |
|--------|---------|-------------|
| `eval` | `TRUE` | Execute the code |
| `echo` | `TRUE` | Show the source code |
| `new_session` | `FALSE` | Start a fresh isolated SLC process for this chunk; `FALSE` reuses the shared session |
| `input_data` | — | Comma-separated R data frame name(s) to transfer into SLC |
| `output_data` | — | Comma-separated SLC dataset name(s) to pull back into R |
| `show_listing` | `TRUE` | Show SAS listing (LST) output below the log |
| `output_files` | — | Override: comma-separated paths to embed. Usually not needed — figures are auto-discovered |
| `fig-cap` | — | Caption(s) for figures. Single string applied to all; list/vector assigns one per figure |

### Shared session (default behaviour)

All `{slc}` chunks in a document share a single SLC process by default (`new_session = FALSE`). WORK datasets, macro variables, and any other session state created in one chunk are visible to all subsequent chunks. The shared process is started on first use and shut down automatically when the document finishes rendering via a knitr `document` hook registered in `R/session.R`.

To run a chunk in an isolated process (one that cannot see state from other chunks), set `new_session = TRUE` on that chunk. To isolate the entire document, add to a setup chunk:

```r
knitr::opts_chunk$set(new_session = TRUE)
```

The internal helpers `get_shared_connection()` and `shutdown_shared_connection()` in `R/session.R` manage the cached `Slc` object stored in `.slcr_env` (defined in `R/zzz.R`).

### How listing output works

Before each chunk submission the engine calls `connection$clear_listing_output()` to avoid stale pages carrying over from a prior chunk. After executing, `connection$get_listing_output()` is called. When the result is non-empty and `show_listing` is not `FALSE`, the listing text is appended to the output wrapped in HTML sentinel comments (`<!-- slc-listing-start -->` / `<!-- slc-listing-end -->`). The bundled JavaScript in `slc-resources.html` detects those sentinels and renders the listing in a separate blue-tinted collapsible block ("📋 SLC Listing") distinct from the grey log block ("📊 SLC Output").

### How image output works

Figures are **auto-discovered** — no `output_files` is needed in most cases. The engine uses two complementary mechanisms after each chunk:

1. **Log parsing**: scans the SAS log for `NOTE: Successfully written image <path>` lines. This captures any figure regardless of the ODS destination.
2. **`&slcr_gpath` scan**: before running user code the engine sets the SAS macro variable `&slcr_gpath` to a per-chunk temp directory. Any image files placed there (e.g. via `ods html gpath="&slcr_gpath"`) are collected after execution.

Both sets of paths are merged, deduplicated, copied into knitr's figure directory, and emitted as pandoc figure markdown (`![caption](path)`).

A basic chart with no special ODS options just works:

````
```{slc fig-cap="Class scatter plot"}
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
```
````

#### Recommended: route figures through `&slcr_gpath`

For reliable, reproducible figure capture — especially in documents that are rendered more than once or contain multiple plot-producing chunks — route ODS output through `&slcr_gpath`. This is a per-chunk temp directory managed by slcR; figures written there are captured cleanly without accumulating files in the working directory or risking stale images from previous renders:

````
```{slc fig-cap="Class scatter plot"}
ods html body='' gpath="&slcr_gpath" style=htmlblue;
proc sgplot data=sashelp.class;
  scatter x=height y=weight;
run;
ods html close;
```
````

Without `gpath="&slcr_gpath"`, SLC writes figures (e.g. `SGPLOT.png`, `SGPLOT1.png`) to the working directory and they persist between renders, which can cause a stale figure from a previous run to appear if the code path changes.

Use `output_files` only when auto-discovery misses a file written to a fully custom path outside `&slcr_gpath`:

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
