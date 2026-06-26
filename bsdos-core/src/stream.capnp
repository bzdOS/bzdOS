@0x8f3c2a1b9d4e5f6a;

# Stream configuration — declarative definition of a single stream instance
struct StreamConfig {
  appId @0 :Text;      # Unique identifier (e.g., "appBrowser")
  app @1 :Text;        # Application binary (e.g., "firefox")
  url @2 :Text;        # Initial URL (e.g., "about:blank")
  user @3 :Text;       # User to run as (e.g., "freebsd")
  width @4 :UInt32;    # Window width in pixels
  height @5 :UInt32;   # Window height in pixels
}

# Stream state — runtime status and metadata
struct StreamState {
  config @0 :StreamConfig;
  status @1 :Status;
  startedAt @2 :Int64;       # Unix timestamp (seconds)
  restartCount @3 :UInt32;   # Number of auto-restarts
  
  enum Status {
    running @0;
    stopped @1;
    failed @2;
  }
}

# Stream registry — persistent state of all streams
struct StreamRegistry {
  version @0 :UInt32;        # Schema version for migration
  streams @1 :List(StreamState);
}

# Control plane messages

# Add a new stream
struct StreamAdd {
  config @0 :StreamConfig;
}

# Remove a stream
struct StreamRemove {
  appId @0 :Text;
}

# List all streams (response)
struct StreamList {
  streams @0 :List(StreamState);
}

# Get status of a single stream (response)
struct StreamStatus {
  state @0 :StreamState;
}

# Generic response
struct StreamResponse {
  success @0 :Bool;
  error @1 :Text;
}
