data_dir = Application.fetch_env!(:beamlet, :data_dir)
File.rm_rf!(data_dir)
File.mkdir_p!(data_dir)

ExUnit.start()
