data_dir = Application.fetch_env!(:beamlet, :data_dir)
File.rm_rf!(data_dir)
File.mkdir_p!(data_dir)

# The platform the image runs, which Beamlet.Policy.DefaultTest pins
# the curated default against.
reference_platform? =
  String.to_integer(System.otp_release()) >= 29 and Version.match?(System.version(), ">= 1.20.0")

ExUnit.start(exclude: if(reference_platform?, do: [], else: [:reference_platform]))
