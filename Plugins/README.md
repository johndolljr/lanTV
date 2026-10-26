# lanTV Plugins

Each plugin lives in its own directory and can be written in any language.

Contract:

- The app loads a `plugin.json` manifest from this directory.
- The manifest declares the command to run.
- The app writes a JSON request to the plugin's `stdin`.
- The plugin writes a JSON response to `stdout`.

Request shape:

```json
{
  "channelNumber": "10.1",
  "channelName": "EXAMPLE-DT",
  "sourceID": "source-id",
  "rawChannelID": "10.1",
  "arguments": {
    "station_url": "https://example.com/station/10",
    "time_zone": "America/New_York"
  },
  "generatedAt": "2026-04-02T15:00:00Z",
  "timeZoneIdentifier": "America/New_York"
}
```

Response shape:

```json
{
  "programmes": [
    {
      "start": "2026-04-02T07:00:00-04:00",
      "stop": "2026-04-02T09:00:00-04:00",
      "title": "Morning News",
      "detail": "Local news and weather.",
      "iconURL": null
    }
  ]
}
```

Notes:

- Unique scrapers can live in their own plugin directory.
- Generic scrapers can read `arguments` and serve multiple channels.
- The app controls refresh cadence and caching per plugin assignment.
