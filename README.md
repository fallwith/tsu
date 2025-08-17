# tsu

tsu is a little utility that outputs tidal information in a brief format
suitable for inclusion within a shell prompt.

Tidal data is fetched once per day from NOAA.gov and cached, allowing `tsu` to
be quite quick.

## Example Output

```shell
$ tsu
3.067↓⏎
```

- The '3.067' value represents the current tide height in feet
- The '↓' arrow represents that the tide is currently receding / the height is dropping
- The '⏎' character denotes that the `tsu` output did not contain a newline)

## Installation

1. Clone this repository and build `tsu` from source using
   [zig](https://ziglang.org/):

```shell
cd tsu
zig build -Doptimize=ReleaseFast -Dstrip=true
```

2. Move the resulting `tsu/zig-out/bin/tsu` binary to a directory in your
   `PATH`.

## Usage

- You will need to know the id for a NOAA.gov station. Head over to
  [tidesandcurrents.noaa.gov](https://tidesandcurrents.noaa.gov/) to find your
  nearest station and note its id.

- In your shell's init configuration, set and export a `NOAA_GOV_STATION_ID`
  environment variable equal to the desired NOAA.gov station id.

- With `tsu` in your `PATH` and the `NOAA_GOV_STATION_ID` environment variable
  set, run `tsu` from the command line to test it. Execute `tsu` twice. The
  first run will handle today's API data fetching from NOAA.gov and cache the
  results and the second run should be much faster by leveraging cache.

- Once you are satisfied that `tsu` is working as desired, leverage it in your
  shell prompt. Here is an example of doing so for the Fish shell:

  ```shell
  # outside of fish_prompt, perform a one-time check for the `tsu` binary
  if type -q tsu
    set tsu_exists 
  end

  function fish_prompt
    # tsu driven tide info (cyan)
    if set -q tsu_exists
      set -l tide_status (tsu)
      set_color cyan
      echo -n "$tide_status "
      set_color normal
    end

    # the rest of the fish_prompt logic goes here...
  ```
