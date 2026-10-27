desc "Build and launch Live2D Avatar"
task :run do
  sh "bash", File.join(__dir__, "scripts", "run.sh")
end

desc "Load your private assets, build and open the personal app"
task :private do
  sh "python3", File.join(__dir__, "scripts", "setup-private.py"), "--launch"
end

task default: :run
