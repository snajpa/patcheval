#!/usr/bin/env ruby

require 'rugged'
require 'ollama-ai'
require 'ollama-ai/errors'

require 'json'
require 'erb'
require 'csv'
require 'fileutils'

tests = {
  "bug-01" => {
    ok_regex: /YES/,
    fail_regex: /NO/,
    patch_part_policy: "OR", # OR or AND
    repair_prompt: "Invalid response, reply only pure YES or NO, does this patch fix a bug:",
    options: {
      #model: 'llama2:7b',
      model: 'llama2:70b',
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.7, seed: 42 }
    },
  },
  "stable-01" => {
    ok_regex: /YES/,
    fail_regex: /NO/,
    patch_part_policy: "OR", # OR or AND
    repair_prompt: "Invalid response, reply only pure YES or NO, backport to stable:",
    options: {
      #model: 'llama2:7b',
      model: 'llama2:70b',
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.7, seed: 42 }
    }
  },
  "security-01" => {
    ok_regex: /YES/,
    fail_regex: /NO/,
    patch_part_policy: "OR", # OR or AND
    repair_prompt: "Invalid response, reply only pure YES or NO:",
    options: {
      #model: 'llama2:7b',
      model: 'llama2:70b',
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.7, seed: 42 }
    }
  },
  "kpatch-build-01" => {
    ok_regex: /COMPLIANT=YES/,
    fail_regex: /COMPLIANT=NO/,
    patch_part_policy: "AND", # OR or AND
    repair_prompt: "Incomplete response, reply must contain explicit COMPLIANT=YES or COMPLIANT=NO:",
    options: {
      #model: 'llama2:7b',
      model: 'llama2:70b',
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.4, seed: 42 }
    }
  },
  "kpatch-build-02" => {
    ok_regex: /YES/,
    fail_regex: /NO/,
    patch_part_policy: "AND", # OR or AND
    repair_prompt: "Invalid response, reply YES or NO, no other response is valid:",
    options: {
      model: 'llama2:70b',
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 32, temperature: 0.6, seed: 42 }
    }
  },
  "commit-summary" => {
    options: {
      model: 'llama2:70b', #-code-q5_0
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 32, temperature: 0.7, seed: 42 }
    }
  },
  "vpsadminos-01" => {
    ok_regex: /ACCEPT/,
    fail_regex: /IGNORE/,
    patch_part_policy: "OR", # OR or AND
    repair_prompt: "Conclusion ACCEPTED/IGNORED (retry %d/%d):",
    options: {
      model: 'llama2:70b', #-code-q5_0
      options: { num_ctx: 2048, repeat_penalty: 1.1, repeat_last_n: 128, temperature: 0.3, seed: 42 }
    }
  },
};

plan = ["commit-summary", "vpsadminos-01", "bug-01", "stable-01", "security-01", "kpatch-build-01", "kpatch-build-02"]
#plan = ["kpatch-build-01"]
#plan = ["commit-summary", "vpsadminos-01"]
skip_commit_on_consecutive_fails = 1

results = {}

Signal.trap("INT") do
  puts
  exit 1
end
Signal.trap("TERM") do
  puts
  exit 1
end

# Create log directory with UTF format of current time
dir = Time.now.strftime('%Y-%m-%d_%H-%M-%S_%Z')
log_dir = File.join('./logs', dir)
FileUtils.mkdir_p(log_dir)
# Update symlink to point to the new log directory
File.unlink('logs/_current') if File.exist?('logs/_current')
FileUtils.ln_sf(dir, './logs/_current')
log_file = File.join(log_dir, 'log.txt')
$logf = File.open(log_file, 'a+')
$logf.sync = true
$csvf = File.open(File.join(log_dir, 'log.csv'), 'a+')
$csvf.sync = true

def log(message)
    $logf.puts message
    puts message
end

def logn(message)
    $logf.print message
    print message
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
  def initialize(test_file)
    @test = File.read("prompts/#{test_file}.erb")
  end
  def generate(params)
    @params = params
    ERB.new(@test).result(binding)
  end
end

ollama = Ollama.new(
  credentials: { address: 'http://localhost:11434' },
  options: { server_sent_events: true,
    connection: {
      request: {
        timeout: 60,
        open_timeout: 60,
        read_timeout: 1800,
        write_timeout: 60
      }
    }
  }
)

# Replace these with the paths to your repository and the tags you want to walk between
repo_path = '/home/snajpa/linux'

start_ref, end_ref = ARGV

unless start_ref && end_ref
  puts "Error: Please provide start and end refs/tags/branches/commits."
  puts "Usage: patcheval [options] <start_ref> <end_ref>"
  exit(1)
end

def find_commit(repo, user_input)    
  # Attempt to resolve commit directly from SHA or through references
  commit = nil
  begin
    # Direct SHA lookup
    commit = repo.lookup(user_input)
  rescue Rugged::InvalidError
    # If direct lookup fails, attempt to find matching reference (branch or tag)
    repo.references.each do |ref|
      if ref.name.end_with?(user_input) || ref.target == user_input
        target = ref.target
        commit = repo.lookup(target.is_a?(String) ? target : ref.target_id)
        break
      end
    end
  rescue Rugged::ReferenceError
    puts "Input does not correspond to a valid commit, tag, or branch."
  end
  commit
end

repo = Rugged::Repository.new(repo_path)

start_commit = find_commit(repo, start_ref)
end_commit = find_commit(repo, end_ref)

if (start_commit == end_commit)
  start_commit = start_commit.parents.first
end

walker = Rugged::Walker.new(repo)
walker.sorting(Rugged::SORT_DATE | Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
walker.push(end_commit)
walker.hide(start_commit)

log "patcheval.rb: Walking between #{start_ref} and #{end_ref}"
log "Start commit: #{start_commit.oid}"
log "End commit:   #{end_commit.oid}"
log "Walk started at:"
log "\t#{Time.now.utc}"
log "\t#{Time.now.localtime}"
log "Commit test plan: #{plan.join(", ")}"
log "Skip commit on consecutive fails: #{skip_commit_on_consecutive_fails}"
log ""

commit_count = 0
walker.each { commit_count += 1 }
log "Total commits: #{commit_count}"
log ""

def response_ok?(response, ok_regex, fail_regex)
  if response =~ ok_regex && response =~ fail_regex
    raise "Response matches both OK and FAIL regex"
  end
  if response =~ ok_regex
    return true
  elsif response =~ fail_regex
    return false
  else
    raise "Unexpected response: #{response}"
  end
end

commit_n = 0

walker.reset
walker.sorting(Rugged::SORT_DATE | Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
walker.push(end_commit)
walker.hide(start_commit)

walker.each do |commit|
  commit_n += 1
  results[commit.oid] = {skipped: true, prompts: {}}
  next if commit.parents.size > 1 && commit.diff(nil).size == 0 # Skip merge commits with no diff

  fails = 0
  log "#{Time.now.localtime} #{commit.oid} #{commit.message.lines.first.chomp} (#{commit_n}/#{commit_count})"
  if commit.parents.size > 1
    log "Merge commit"
    next
  end
  test_n = 0
  response_first = ""
  response = ""
  plan.each do |test_name|
    test_n += 1
    test = tests[test_name]
    raise "Test not found: #{test_name}" if test.nil?
    starting = Time.now
    log_verbose "\n"
    logn " test: %20s" % "#{test_name}"
    prompt_generator = PromptGenerator.new(test_name)
    #ok = run_test_on_commit(commit, test[:ok_regex], test[:fail_regex], test[:repair_prompt], prompt_generator, ollama, test[:options], )
    ok = test[:patch_part_policy] == "AND"
    diff = commit.diff
    patch_s = ""
    diff.each_patch do |patch|
      patch_s += patch.to_s + "\n"
    end
    prompts_length = 0
    responses_length = 0
    prompt = prompt_generator.generate({diff: patch_s,
                                        commit: commit.oid,
                                        message_short: commit.message.lines.first.chomp,
                                        message: commit.message,
                                        plan_response_prev: response,
                                        plan_response_first: response_first})
    context = []
    retries = 0
    begin
      retries += 1
      result = ollama.generate(test[:options].merge({prompt: prompt, context: context, stream: false}))
      response = result.last["response"]
      response_first = response if test_n == 1
      context = result.last["context"]
      log_verbose "\n\n" + prompt
      log_verbose "\n" + response + "\n\n"
      log_verbose "prompt length: #{prompt.length}"
      log_verbose "response length: #{response.length}"
      prompts_length += prompt.length
      responses_length += response.length
      if !(test[:ok_regex].nil? || test[:fail_regex].nil?)
        ok = (test[:patch_part_policy] == "AND") ? (ok && response_ok?(response, test[:ok_regex], test[:fail_regex]))
                                                 : (ok || response_ok?(response, test[:ok_regex], test[:fail_regex]))
      end
    rescue RuntimeError
      log_verbose "Retrying... (#{retries}/5)"
      prompt = test[:repair_prompt] % [retries, 5]
      if retries < 5
        retry
      else
        log_verbose "Too many retries, skipping commit"
        ok = nil
      end
    end
    res = "unknown"
    if ok == true
      res = "ok"
    elsif ok == false
      res = "fail"
    end
    if test[:ok_regex].nil? && test[:fail_regex].nil?
      res = "%5d long" % response.length
    end
    ending = Time.now
    elapsed = ending - starting
    logn " %10s " % res
    logn "%5.2fs" % elapsed
    logn "  in: %5d B" % prompts_length
    logn "  out: %5d B" % responses_length
    logn "  %6.2f B/s\n" % ((prompts_length + responses_length) / elapsed)
    log_csv [commit.oid, commit.message.lines.first.chomp, test_name, res, prompts_length, responses_length, elapsed]
    results[commit.oid][:prompts][test_name] = {result: res, elapsed: elapsed}
    if !!skip_commit_on_consecutive_fails && ok && !test[:ok_regex].nil? && !test[:fail_regex].nil?
      fails = 0
    end
    if !!skip_commit_on_consecutive_fails && !ok && !test[:ok_regex].nil? && !test[:fail_regex].nil?
      fails += 1
      if fails >= skip_commit_on_consecutive_fails
        log_verbose "Skipping commit due to consecutive fails"
        break
      end
    end
  end
  results[commit.oid][:skipped] = false
  log_verbose "\n=====\n\n"
end