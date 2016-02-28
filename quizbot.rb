#!/usr/bin/env ruby

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'net/http'
require 'json'
require 'yaml'

if File.exist?('config.yml')
  config = YAML.load_file("config.yml")
  if !config["jid"] || !config["secret"] || !config["room"]
    puts "Config file missing an option"
    exit
  end
elsif ARGV.size != 3
  puts "Usage: #{$0} <jid> <password> <room@conference/nick>"
  exit
else
  config = Hash.new
  config["jid"] = ARGV[0]
  config["password"] = ARGV[1]
  config["room"] = ARGV[2]
end

# generate questionpool from MoxQuizz quizdata files
questionpool = []

# files need to be converted to utf-8 first
# e.g. iconv -f ISO-8859-15 -t UTF-8
Dir.glob('quizdata/*.utf8') do |item|
  File.open( item ).each do |line|
    if not line.start_with?("#")
      if line == "\n"
        if $hash
          questionpool.push($hash)
          $hash = nil
        end
      else
        if not $hash
          $hash = Hash.new
        end
        linesplit = line.split(": ", 2)
        $hash[linesplit.first.strip] = linesplit.last.strip
      end
    end
  end
end

#Jabber::debug = true
cl = Jabber::Client.new(Jabber::JID.new(config["jid"]))
cl.connect
cl.auth(config["password"])

# For waking up...
mainthread = Thread.current

# This is the SimpleMUCClient helper!
m = Jabber::MUC::SimpleMUCClient.new(cl)

# SimpleMUCClient callback-blocks

m.on_message { |time,nick,text|
  # Avoid reacting on messaged delivered as room history
  unless time
    # Bot: startquiz
    if text.strip =~ /^(.+?): startquiz ([0-9]|[0-9]{2})$/
      if $1.downcase == m.jid.resource.downcase
        if $2
          $question = questionpool.sample
          $questioncount = $2.to_i - 1
          m.say($question["Question"])
          $scoreboard = Hash.new
        end
      end
    # Bot: next
    elsif text.strip =~ /^(.+?): next$/
      if $question
        $question = questionpool.sample
        m.say($question["Question"])
      else
        m.say("No quiz has been started!")
      end
    # Bot: exit
    elsif text.strip =~ /^(.+?): exit$/
      if $1.downcase == m.jid.resource.downcase
        m.exit "Exiting on behalf of #{nick}"
        mainthread.wakeup
      end
    # look for anything if a question was asked
    elsif $question
      if $question["Regexp"]
        if /#{$question["Regexp"]}/ =~ text
          answered = true
        end
      elsif text.casecmp($question["Answer"]) == 0
        answered = true
      end
      if answered == true
        m.say("Correct answer #{nick}!")
        if $scoreboard.has_key?(nick)
          $scoreboard[nick] = $scoreboard[nick] + 1
        else
          $scoreboard[nick] = 1
        end
        if $questioncount > 0
          $question = questionpool.sample
          $questioncount = $questioncount-1
          m.say($question["Question"])
        else
          $question = nil
          m.say("(.•ˆ•… Scoreboard …•ˆ•.)")
          $scoreboard.each do |key, val|
            m.say("#{key}: #{val}")
          end
        end
      end
    end
  end
}

m.join(config["room"])

# Wait for being waken up by m.on_message
Thread.stop

cl.close
