#!/usr/bin/env ruby

require 'rugged'
require 'ollama-ai'

require 'erb'
require 'fileutils'

# Create log directory with UTF format of current time
dir = Time.now.strftime('%Y-%m-%d_%H-%M-%S_%Z')
log_dir = File.join('./logs', dir)
FileUtils.mkdir_p(log_dir)
# Update symlink to point to the new log directory
File.unlink('logs/current') if File.exist?('logs/current')
FileUtils.ln_sf(dir, './logs/current')
log_file = File.join(log_dir, 'log.txt')
$logf = File.open(log_file, 'a+')
$logf.sync = true

def log(message)
  $logf.puts message
  puts message
end

def log_verbose(message)
  $logf.puts message
end

class PromptGenerator
  def initialize(template_file)
    @template = File.read("prompts/#{template_file}.erb")
  end
  def generate(params)
    @params = params
    ERB.new(@template).result(binding)
  end
end


prompt_kpatch = PromptGenerator.new('kpatch-build')

ollama = Ollama.new(
  credentials: { address: 'http://localhost:11434' },
  options: { server_sent_events: true }
)

# Replace these with the paths to your repository and the tags you want to walk between
repo_path = '/home/snajpa/linux'
start_tag = 'v6.7-rc1'
end_tag = 'v6.7-rc2'

# Open the repository
repo = Rugged::Repository.new(repo_path)

# Retrieve the commit objects for the start and end tags
start_commit = repo.tags[start_tag].target
end_commit = repo.tags[end_tag].target

# Create a Walker object to traverse the commits
walker = Rugged::Walker.new(repo)
walker.sorting(Rugged::SORT_DATE | Rugged::SORT_TOPO | Rugged::SORT_REVERSE)

# Push the range of commits between the start and end tags onto the walker
walker.push(end_commit)
walker.hide(start_commit)

def response_ok?(response, ok_regex, fail_regex)
  if response =~ ok_regex
    return true
  elsif response =~ fail_regex
    return false
  else
    raise "Unexpected response: #{response}"
  end
end

# Iterate over each commit in the walker
commits = {:ok => [], :bad => []}

def log_commits(commits)
    log "Commits:"
    log "  OK: #{commits[:ok].size}"
    commits[:ok].each do |commit|
        log "    #{commit}"
    end
    log "  BAD: #{commits[:bad].size}"
    commits[:bad].each do |commit|
        log "    #{commit}"
    end
end

Signal.trap("INT") do
    log_commits(commits)
    exit 1
end
Signal.trap("TERM") do
    log_commits(commits)
    exit 1
end

walker.each do |commit|
  next if commit.parents.size > 1 && commit.diff(nil).size == 0 # Skip merge commits with no diff

  log "#{commit.oid} #{commit.message.lines.first.chomp}"

  if commit.parents.size > 1
    log "Merge commit"
  else
    ok = true
    diff = commit.diff
    diff.each_patch do |patch|
        prompt = prompt_kpatch.generate({ diff: patch.to_s })
        context = []
        log_verbose prompt
        retries = 0
        begin
            retries += 1
            result = ollama.generate({
                                    model: 'llama2:13b',
                                    context: context,
                                    prompt: prompt,
                                    stream: false,
                                    options: { num_ctx: 4096, repeat_penalty: 1.2 }
                                })
            response = result.first["response"]
            log_verbose response

            ok = ok && response_ok?(response, /COMPATIBLE\s*=\s*YES/, /COMPATIBLE\s*=\s*NO/)
        rescue RuntimeError
            log "    Retrying... (#{retries}/5)"
            context = result.first["context"]
            prompt = "Invalid response, reply only pure COMPATIBLE=YES or COMPATIBLE=NO, no other response is valid:"
            if retries < 5
                retry
            end
        end
    end

    if ok
        commits[:ok] << commit.oid
        log " => Patch is good"
    else
        commits[:bad] << commit.oid
        log " => Patch is bad"
    end
    log_verbose "===============================================\n\n\n"
  end
end