#!/usr/bin/env ruby

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'net/http'
require 'json'

if ARGV.size != 3
  puts "Usage: #{$0} <jid> <password> <room@conference/nick>"
  exit
end

# generate questionpool from MoxQuizz quizdata files
questionpool = []

# files need to be converted to utf-8 first
# e.g. iconv -f ISO-8859-15 -t UTF-8
Dir.glob('quizdata/*.utf8') do |item|
  File.open( item ).each do |line|
    if not line.start_with?("#")
      if not line == "\n"
        if line.start_with?("Question")
          $hash = Hash.new
          $hash["question"] = line.split(": ").last.strip
        elsif line.start_with?("Answer")
          $hash["answer"] = line.split(": ").last.strip
          questionpool.push($hash)
        end
      end
    end
  end
end

#Jabber::debug = true
cl = Jabber::Client.new(Jabber::JID.new(ARGV[0]))
cl.connect
cl.auth(ARGV[1])

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
          m.say($question["question"])
          #puts ($question["answer"])
          $scoreboard = Hash.new
        end
      end
    # Bot: next
    elsif text.strip =~ /^(.+?): next$/
      if $question
        $question = questionpool.sample
        m.say($question["question"])
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
      if text.casecmp($question["answer"]) == 0
        m.say("Correct answer #{nick}!")
        if $scoreboard.has_key?(nick)
          $scoreboard[nick] = $scoreboard[nick] + 1
        else
          $scoreboard[nick] = 1
        end
        if $questioncount > 0
          $question = questionpool.sample
          $questioncount = $questioncount-1
          m.say($question["question"])
          #puts ($question["answer"])
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

m.join(ARGV[2])

# Wait for being waken up by m.on_message
Thread.stop

cl.close
