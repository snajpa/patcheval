#!/usr/bin/env ruby

require 'rugged'
require 'ollama-ai'
require 'ollama-ai/errors'

require 'erb'
require 'csv'
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
$csvf = File.open(File.join(log_dir, 'log.csv'), 'a+')
$csvf.sync = true

def log(message)
    $logf.puts message
    puts message
end

def log_verbose(message)
  $logf.puts message
end

def log_csv(a)
    message = a.to_csv
    $csvf.puts message
    log_verbose(message)
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

skip_commit_on_consecutive_fails = 1
templates = [
    {
        :name => 'bug-01',
        :ok_regex => /YES/,
        :fail_regex => /NO/,
        :repair_prompt => "Invalid response, reply only pure YES or NO, does this patch fix a bug:",
        :options => {
            model: 'llama2:7b',
            stream: false,
            options: { num_ctx: 4096, repeat_penalty: 1.15, repeat_last_n: 128, temperature: 0.65, seed: 42 }
        }
    },
    # { # TODO
    #     :name => 'stability-01',
    #     :ok_regex => /YES/,
    #     :fail_regex => /NO/,
    #     :repair_prompt => "Invalid response, reply only pure YES or NO, does this patch improve stability:",
    #     :options => {
    #         model: 'llama2:7b',
    #         stream: false,
    #         options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 128, temperature: 0.85, seed: 42 }
    #     }
    # },
    {
        :name => 'security-01',
        :ok_regex => /YES/,
        :fail_regex => /NO/,
        :repair_prompt => "Invalid response, reply only pure YES or NO:",
        :options => {
            model: 'llama2:13b',
            stream: false,
            options: { num_ctx: 4096, repeat_penalty: 1.15, repeat_last_n: 128, temperature: 0.65, seed: 42 }
        }
    },
    {
        :name => 'kpatch-build-01',
        :ok_regex => /COMPATIBLE\s*=\s*YES/,
        :fail_regex => /COMPATIBLE\s*=\s*NO/,
        :repair_prompt => "Invalid response, reply only pure COMPATIBLE=YES or COMPATIBLE=NO, no other response is valid:",
        :options => {
            model: 'llama2:13b',
            stream: false,
            options: { num_ctx: 4096, repeat_penalty: 1.15, repeat_last_n: 128, temperature: 0.65, seed: 42 }
        }
    },
    {
        :name => 'kpatch-build-02',
        :ok_regex => /YES/,
        :fail_regex => /NO/,
        :repair_prompt => "Invalid response, reply only pure YES or NO, no other response is valid:",
        :options => {
            model: 'llama2:7b',
            options: { num_ctx: 4096, repeat_penalty: 1.15, repeat_last_n: 128, temperature: 0.65, seed: 42 }
        }
    },
];

ollama = Ollama.new(
  credentials: { address: 'http://localhost:11434' },
  options: { server_sent_events: true }
)

# Replace these with the paths to your repository and the tags you want to walk between
repo_path = '/home/snajpa/linux'

start_tag, end_tag = ARGV

unless start_tag && end_tag
  puts "Error: Please provide start and end tags."
  puts "Usage: patcheval [options] <start_tag> <end_tag>"
  exit(1)
end

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

Signal.trap("INT") do
    exit 1
end
Signal.trap("TERM") do
    exit 1
end

def run_template_on_commit(commit, ok_regex, fail_regex, repair_prompt, prompt_generator, ollama, ollama_options)
    ok = true
    diff = commit.diff
    diff.each_patch do |patch|
        prompt = prompt_generator.generate({diff: patch.to_s, commit: commit.oid, message_first: commit.message.lines.first.chomp, message: commit.message})
        context = []
        retries = 0
        begin
            retries += 1
            result = ollama.generate(ollama_options.merge({prompt: prompt, context: context, stream: false}))
            response = result.first["response"]
            log_verbose "\n" + prompt
            log_verbose "\n" + response + "\n\n"
            ok = ok && response_ok?(response, ok_regex, fail_regex)
        rescue RuntimeError
            log_verbose "Retrying... (#{retries}/5)"
            context = result.first["context"]
            prompt = repair_prompt
            if retries < 5
                retry
            else
                log_verbose "Too many retries, skipping commit"
                ok = false
            end
        end
    end
    ok
end


walker.each do |commit|
    next if commit.parents.size > 1 && commit.diff(nil).size == 0 # Skip merge commits with no diff

    fails = 0
    log "#{commit.oid} #{commit.message.lines.first.chomp}"
    if commit.parents.size > 1
        log "Merge commit"
    else
        templates.each do |template|
            starting = Time.now
            log_verbose "\n"
            log " Template: #{template[:name]}\n"
            prompt_generator = PromptGenerator.new(template[:name])
            ok = run_template_on_commit(commit, template[:ok_regex], template[:fail_regex], template[:repair_prompt], prompt_generator, ollama, template[:options])
            res = "unknown"
            if ok == true
                res = "ok"
            elsif ok == false
                res = "fail"
            end
            ending = Time.now
            elapsed = ending - starting
            log_csv [commit.oid, commit.message.lines.first.chomp, template[:name], res, elapsed]
            if !!skip_commit_on_consecutive_fails && ok
                fails = 0
            end
            if !!skip_commit_on_consecutive_fails && !ok
                fails += 1
                if fails >= skip_commit_on_consecutive_fails
                    log_verbose "Skipping commits due to consecutive fails"
                    break
                end
            end
        end
        log_verbose "\n=====\n\n"
    end
end