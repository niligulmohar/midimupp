#! /usr/bin/env ruby

require 'asound'
require 'Korundum'

######################################################################
#  _____                 _       _____               _
# | ____|_   _____ _ __ | |_    |_   _| __ __ _  ___| | __
# |  _| \ \ / / _ \ '_ \| __|     | || '__/ _` |/ __| |/ /
# | |___ \ V /  __/ | | | |_ _    | || | | (_| | (__|   <
# |_____| \_/ \___|_| |_|\__( )   |_||_|  \__,_|\___|_|\_\
#                           |/

class Event
  class << self
    def event_attr(*names)
      names.each do |name|
        n = name.to_s
        class_eval('attr_reader :%s; def %s=(val) @%s=val; update_lane_events; end' % [n, n, n])
      end
    end
  end
  attr_reader :start
  def start=(value)
    @start = value
    update_lane_events
    if @array
      a = @array
      a.delete(self)
      a.insert(self)
    end
  end
  attr_accessor :next, :previous, :array
  def initialize(track, start)
    @track = track
    @lane_events = []
    @start = start
  end
  def update_lane_events
    @lane_events.each{ |n| n.update }
  end
  def add_lane_event(lane_event)
    @lane_events.push(lane_event)
  end
  def next_start
    if @next
      @next.start
    else
      @track.sequence.length
    end
  end
  def alsa_event?
    true
  end
  def play_delayed?
    true
  end
  def fill_alsa_event(ev)
    if ev.type == 0
      print "%s\n" % self
      fail
    end
    ev.schedule_tick($queue, 0, @start)
  end
end

class MetaEvent < Event
  event_attr :type, :data
  def initialize(track, start, type = nil, data = nil)
    super(track, start)
    @type = type
    @data = data
  end
  def alsa_event?
    false
  end
end

class Tempo < MetaEvent
  event_attr :bpm
  def initialize(track, start, bpm)
    super(track, start)
    track.add_tempo(self)
    @bpm = bpm
  end
  def alsa_event?
    true
  end
  def fill_alsa_event(ev)
    ev.set_queue_tempo($queue, 60000000 / @bpm)
    super
  end
end

class TimeSignature < MetaEvent
  event_attr :n, :d, :metronome, :the_wierd_one
  def initialize(track, start, n, d, metronome, the_wierd_one)
    super(track, start)
    track.add_time_signature(self)
    @n = n
    @d = d
    @metronome = metronome
    @the_wierd_one = the_wierd_one
  end
end

class Note < Event
  event_attr :channel
  event_attr :pitch, :velocity, :length
  def initialize(track, start, channel, pitch, velocity, length)
    super(track, start)
    track.add_note(self)
    @channel = channel
    @pitch = pitch
    @velocity = velocity
    @length = length
  end
  def end=(time)
    self.length = time - @start
  end
  def to_s
    "#<Note: #@start #@channel #@pitch #@velocity #@length>"
  end
  def fill_alsa_event(ev)
    ev.set_note(@channel, @pitch, @velocity, @length)
    super
  end
  def play_delayed?
    false
  end
end

class Controller
  class << self
    def continuous(n)
      (@@continuous_ctls ||= {})[n] ||= ContinuousController.new(n)
    end
    def pitch_bend
      @@pitch_bend ||= PitchBend.new
    end
    def program_change
      @@program_change ||= ProgramChange.new
    end
    def all
      unless class_variables.member?('@@all')
        @@all = []
        @@all.push(pitch_bend)
        @@all.push(program_change)
        CONTINUOUS_CONTROLLER_NAMES.each_key do |n|
          @@all.push(continuous(n))
        end
      end
      return @@all
    end
  end
  def transform_value(value)
    value
  end

  attr_reader :name, :range, :center
end

class PitchBend < Controller
  def initialize
    @name = 'Pitch bend'
    @range = (0 .. 2**14-1)
    @center = 2**14 / 2
  end
  def fill_alsa_event(c, ev)
    ev.set_pitchbend(c.channel, c.value)
  end
  def transform_value(value)
    if value >= 0x2000
      value - 0x4000
    else
      value + 0x2000
    end
  end
end

class ProgramChange < Controller
  def initialize
    @name = 'Program change'
    @range = (0..127)
    @center = 0
  end
  def fill_alsa_event(c, ev)
    ev.set_pgmchange(c.channel, c.value)
  end
end

CONTINUOUS_CONTROLLER_NAMES = {
  0x00 => 'Bank select',
  0x01 => 'Modulation wheel',
  0x06 => 'Data entry (MSB)',
  0x26 => 'Data entry (LSB)',
  0x07 => 'Volume',
  0x0a => 'Pan',
  0x5b => 'Effects 1 depth (External effects)',
  0x5d => 'Effects 3 depth (Chorus)',
  0x64 => 'RPN (LSB)',
  0x65 => 'RPN (MSB)',
}
class ContinuousController < Controller
  attr_reader :n
  def initialize(n)
    @n = n
    @name = CONTINUOUS_CONTROLLER_NAMES[n] || 'Continuous controller %02x' % @n
    @range = (0..127)
    @center = 0
  end
  def fill_alsa_event(c, ev)
    ev.set_controller(c.channel, @n, c.value)
  end
end

class ControllerChange < Event
  event_attr :channel, :value
  attr_reader :controller
  def initialize(track, start, channel, controller, value)
    super(track, start)
    @channel = channel
    @controller = controller
    @value = value
    track.add_controller_change(self)
  end
  def prev_value
    if @previous
      @previous.value
    else
      @controller.center
    end
  end
  def to_s
    "#<ControllerChange: #@start #@channel #@controller #@value>"
  end
  def fill_alsa_event(ev)
    @controller.fill_alsa_event(self, ev)
    super
  end
end

######################################################################

class OrderedEvents < Array
  attr_accessor :play_ptr
  def index_for(start)
    left, right = [0, length-1]
    while left <= right
      mid = ((left+right)*0.5).floor
      if start > self[mid].start
        left = mid+1
      elsif start < self[mid].start
        right = mid-1
      else
        return mid
      end
    end
    #print "%d, %d\n" % [left, right]
    fail if right != left-1
    return left
  end
  def insert(event)
    event.array = self
    i = index_for(event.start)
    if i == 0
      event.previous = nil
    else
      event.previous = self[i-1]
      self[i-1].next = event
    end
    n = self[i]
    event.next = n
    if n
      n.previous = event
    end
    super(i, event)
  end
  def push(event)
    super
    event.next = nil
    event.prev = self[-2]
    if length > 1
      self[-2].next = event
      fail if event.start < event.prev.start
    end
  end
  def delete(event)
    event.array = nil
    if event.previous
      event.previous.next = event.next
    end
    if event.next
      event.next.previous = event.previous
    end
    super(event)
  end
  def push
    fail
  end
end

######################################################################

CURSOR_PEN = Qt::Pen.new(Qt::Color::new(240, 255, 128, Qt::Color::Hsv), 4)

class Cursor
  attr_reader :time
  def initialize(sequence)
    @sequence = sequence
    @time = 0
    @lines = {}
  end
  def time=(pulse)
    @time = pulse
    @lines.each do |view, line|
      # TODO: only update visible views
      view.update
      line.set_points(@time, 0, @time, view.height)
    end
  end
  def add_view(view)
    line = Qt::CanvasLine.new(view)
    @lines[view] = line
    line.set_points(@time, 0, @time, view.height)
    line.set_z(1000)
    line.set_pen(CURSOR_PEN)
    line.show
  end
end

class Sequence
  attr_accessor :ppqn, :length, :tracks, :tempo_track, :play_cursor
  def initialize(with_tracks = false)
    @ppqn = 96
    @length = @ppqn*4*10
    @tempo_track = nil
    @tracks = []
    if with_tracks
      3.times do
        Track.new(self)
      end
      Tempo.new(@tempo_track, 0, 120)
      TimeSignature.new(@tempo_track, 0, 4, 4, @ppqn, 8)
    end
    @cursors = [Cursor.new(self)]
    @play_cursor = @cursors.first
  end
  def add_track(track)
    if @tempo_track
      @tracks.push(track)
    else
      @tempo_track = track
    end
  end
  def setup_alsa_queue
    $queue.ppq = @ppqn
  end
  def bar_beat_pulse(pulse)
    if @tempo_track.time_signatures.empty?
      return pulse
    else
      ts = @tempo_track.time_signatures.first
      bars = 1
      while pulse > ts.next_start and ts.next
        bars += (ts.next_start - ts.start) / @ppqn * 4 * ts.n / ts.d
        ts = ts.next
      end
      time = pulse - ts.start
      beat_time = @ppqn * 4 / ts.d
      bar_time = beat_time * ts.n
      bars += time / bar_time
      beats = (time / beat_time) % ts.n + 1
      remainder = time % beat_time
      return [bars, beats, remainder]
    end
  end
  def bar_beat_pulse_str(pulse)
    "%d:%2d.%4d" % bar_beat_pulse(pulse)
  end
end

class SequenceAlsaPlayer
  # TODO: base buffer fill on clock time instead of ppqn
  # TODO: prevent blocking by filling the alsa buffer
  BUFFER_QN_LENGTH = 8
  def initialize(sequence, port, offset = 0)
    @sequence = sequence
    @port = port
    @pos = offset
    @queues = []
    ([@sequence.tempo_track] + @sequence.tracks).each{ |track| @queues += track.event_queues }
    #print "%s\n" % [queues]
    @queues.each do |queue|
      queue.play_ptr = queue.first
      # while queue.play_ptr and queue.play_ptr.start < @pos
      #   queue.play_ptr = queue.play_ptr.next
      # end
    end
    @sequence.setup_alsa_queue
    $queue.tick_time = @pos
    $queue.continue
  end
  def queue_more_alsa_events(queue)
    if queue.tick_time < @pos - @sequence.ppqn * BUFFER_QN_LENGTH / 2
      return
    end
    start = @pos
    @pos += @sequence.ppqn * BUFFER_QN_LENGTH
    @queues.each do |queue|
      while queue.play_ptr && queue.play_ptr.start < @pos
        event = queue.play_ptr
        if event.alsa_event? and (event.start >= start or event.play_delayed?)
          alsa_event = Snd::Seq::Event.new
          alsa_event.source = @port
          alsa_event.set_subs
          event.fill_alsa_event(alsa_event)
          result = $seq.event_output(alsa_event)
          print "%d " % result
          if result < 0
            print "%s\n" % event
            fail
          end
        end
        queue.play_ptr = queue.play_ptr.next
      end
    end
  end
end

class Track
  attr_reader :sequence, :time_signatures
  attr_accessor :name
  def initialize(sequence)
    @sequence = sequence
    sequence.add_track(self)
    @notes = OrderedEvents.new
    @note_lanes = []
    @controllers = {}
    @controller_lanes = {}
    @name = '<unnamed>'
    @time_signatures = OrderedEvents.new
    @tempos = OrderedEvents.new

    ############################################
    # 100.times do
    #   add_note(Note.new(self, rand(length), rand(128), rand(128), rand(length/20)))
    # end
    # [1,2].each do |n|
    #   100.times do
    #     add_controller_change(ControllerChange.new(self, rand(length), Controller.continuous(n), rand(128)))
    #   end
    # end
    # 100.times do
    #   add_controller_change(ControllerChange.new(self, rand(length), Controller.pitch_bend, rand(2**14)))
    # end
    ############################################
  end
  def controllers
    @controllers.keys
  end
  def has_controller?(c)
    @controllers.has_key?(c)
  end
  def device_controllers
    (Controller.all + @controllers.keys).uniq
  end
  def add_event(event)
  end
  def add_note_lane(lane)
    @note_lanes.push(lane)
    @notes.each do |note|
      lane.add_note(note)
    end
  end
  def add_note(note)
    add_event(note)
    @notes.insert(note)
    @note_lanes.each do |lane|
      lane.add_note(note)
    end
  end
  def add_controller_lane(lane)
    (@controller_lanes[lane.controller] ||= []).push(lane)
    controller_events = @controllers[lane.controller]
    if controller_events
      controller_events.each do |event|
        lane.add_controller(event)
      end
    end
  end
  def add_controller_change(event)
    add_event(event)
    (@controllers[event.controller] ||= OrderedEvents.new).insert(event)
    lanes = @controller_lanes[event.controller]
    if lanes
      lanes.each do |lane|
        lane.add_controller(event)
      end
    end
  end
  def add_time_signature(time_signature)
    add_event(time_signature)
    @time_signatures.insert(time_signature)
  end
  def add_tempo(tempo)
    add_event(tempo)
    @tempos.insert(tempo)
  end
  def event_queues
     @controllers.values + [@tempos, @notes]
  end
end

######################################################################

def read_smf(file)
  sequence = Sequence.new
  while not file.eof?
    id = file.read(4)
    length = file.read(4).unpack('N').first
    chunk = file.read(length)
    case id
    when 'MThd'
      format, tracks, ppqn = chunk.unpack('nnn')
      fail if format != 1
      sequence.ppqn = ppqn
      #print "format: %d; tracks: %d, ppqn: %d\n" % [format, tracks, ppqn]
    when 'MTrk'
      #hexdump(chunk)
      track = Track.new(sequence)
      TrackReader.new(chunk, track)
    else
      print "*** %s: %d\n" % [id, length]
      fail
    end
  end
  #print "read_smf done\n"
  return sequence
end

class TrackReader
  def initialize(chunk, track)
    @ptr = 0
    @track = track
    @chunk = chunk
    @running_notes = {}
    @time = 0

    catch(:done) do
      while not eof?
        @time += read_variable_length_quantity
        # print "--- time: %8d" % @time
        read_event
      end
      fail
    end
  end
  def eof?
    @ptr >= @chunk.length
  end
  def read_byte
    @ptr += 1
    return @chunk[@ptr - 1]
  end
  def read(bytes)
    @ptr += bytes
    return @chunk[@ptr - bytes..@ptr]
  end
  def read_variable_length_quantity
    result = 0
    loop do
      byte = read_byte
      result = (result << 7) + (byte & 0x7f)
      if byte & 0x80 == 0
        return result
      end
    end
  end
  def read_event
    status = read_byte
    if status == 0xff
      type = read_byte
      length = read_variable_length_quantity
      data = read(length)
      case type
      # when 0x01
      #   # print "    Text: %s\n" % data.strip
      # when 0x02
      #   # print "    Copyright: %s\n" % data.strip
      when 0x03
        # print "    Track name: %s\n" % data.strip
        @track.name = data
      # when 0x06
      #   # print "    Marker: %s\n" % data.strip
      # when 0x21
      #   # print "    Midi port event\n"
      when 0x2f
        if eof?
          if @track.sequence.length < @time
            @track.sequence.length = @time
          end
          throw :done
        else
          fail
        end
        fail unless eof?
      when 0x51
        uspqn = ("\0"+data).unpack('N').first
        bpm = 60000000.0 / uspqn
        Tempo.new(@track, @time, bpm)
      when 0x58
        numerator, d, metronome, midi_qn = data.unpack('CCCC')
        denominator = 2**d
        TimeSignature.new(@track, @time, numerator, denominator, metronome, midi_qn)
        if midi_qn != 8
          print "%d 32s per qn\n" % midi_qn
        end
      # when 0x59
      #   n_sharps, minor = data.unpack('CCCC')
      #   # print "    Key signature: %d %d \n" % [n_sharps, minor]
      else
        #print "    Meta-event %02x\n" % type
        #hexdump(data)
        MetaEvent.new(@track, @time, type, data)
      end
    else
      if (status & 0x80) == 0
        # print '  ->'
        data0 = status
        status = @old_status
      else
        # print '    '
        @old_status = status
        data0 = read_byte
      end

      type = (status & 0xf0) >> 4
      channel = status & 0x0f
      # print '    (%2d) ' % (channel+1)

      case type
      when 0x8
        note = data0
        velocity = read_byte
        if @running_notes.has_key?([channel, note])
          @running_notes[[channel, note]].end = @time
          @running_notes.delete([channel, note])
        end
      when 0x9
        note = data0
        velocity = read_byte
        if velocity == 0
          if @running_notes.has_key?([channel, note])
            @running_notes[[channel, note]].end = @time
            @running_notes.delete([channel, note])
          end
        else
          @running_notes[[channel, note]] = Note.new(@track, @time, channel, note, velocity, 100)
        end
      when 0xa
        note = data0
        value = read_byte
        print "Note aftertouch: %x, %x\n" % [note, value]
        fail
      when 0xb
        controller = data0
        value = read_byte
        ControllerChange.new(@track, @time, channel, Controller.continuous(controller), value)
      when 0xc
        program = data0
        ControllerChange.new(@track, @time, channel, Controller.program_change, program)
      when 0xd
        value = data0
        print "Channel aftertouch: %x, %x\n" % [value]
        fail
      when 0xe
        value = (data0 << 7) + read_byte
        ControllerChange.new(@track, @time, channel, Controller.pitch_bend, value)
      else
        # print "Status: %02x\n" % status
        fail
      end
    end
  end
end

def hexdump(str)
  str.each_byte do |byte|
    print " %02x" % byte
  end
  print "\n"
end

######################################################################
#  _                     _   _       _           _
# | |    __ _ _ __   ___| \ | | ___ | |_ ___    | |    __ _ _ __   ___
# | |   / _` | '_ \ / _ \  \| |/ _ \| __/ _ \   | |   / _` | '_ \ / _ \
# | |__| (_| | | | |  __/ |\  | (_) | ||  __/_  | |__| (_| | | | |  __/
# |_____\__,_|_| |_|\___|_| \_|\___/ \__\___( ) |_____\__,_|_| |_|\___|
#                                           |/

NO_PEN = Qt::Pen.new(Qt::NoPen)

module LaneEvent
  def event_init(event, lane)
    @event = event
    @lane = lane
    sub_event_init
    update
    event.add_lane_event(self)
  end
  def sub_event_init
  end
end

class LaneNote < Qt::CanvasRectangle
  include LaneEvent
  def initialize(event, lane)
    super(lane)
    event_init(event, lane)
    show
  end
  def update
    start = @event.start
    velocity = @event.velocity
    set_x(start)
    set_y(@event.pitch)
    set_z(start)
    set_size(@event.length, 2)
    set_color(velocity)
  end
  def set_color(val)
    set_brush(Qt::Brush.new(Qt::Color.new(0, val * 2.0, 255 - val * 0.35, Qt::Color::Hsv)))
  end
end

class LaneNoteVelocity < LaneNote
  def update
    velocity = @event.velocity
    set_x(@event.start)
    set_y(0)
    set_z(127 - velocity)
    set_size(@event.length, velocity)
    set_color(velocity)
  end
end

COLOR_SATURATION = 96
COLOR_VALUE = 224
def color(hue)
  Qt::Color.new(hue, COLOR_SATURATION, COLOR_VALUE, Qt::Color::Hsv)
end
CONTROLLER_LANE_COLOR = color(360-135)
CONTROLLER_PEN = Qt::Pen.new(CONTROLLER_LANE_COLOR.dark(300), 2)
CONTROLLER_BRUSH = Qt::Brush.new(CONTROLLER_LANE_COLOR.dark(150))

class ControllerLaneEvent
  include LaneEvent
  def initialize(event, lane)
    event_init(event, lane)
  end
  def sub_event_init
    [:@horizontal_line, :@vertical_line].each do |v|
      line = Qt::CanvasLine.new(@lane)
      line.set_pen(CONTROLLER_PEN)
      line.set_z(2)
      instance_variable_set(v, line)
    end
    @box = Qt::CanvasRectangle.new(@lane)
    @box.set_pen(NO_PEN)
    @box.set_brush(CONTROLLER_BRUSH)
    @box.set_z(1)
  end
  def update
    next_start = @event.next_start
    prev_value = @event.controller.transform_value(@event.prev_value)
    value = @event.controller.transform_value(@event.value)
    center = @event.controller.center
    size = (value - center).abs
    @vertical_line.set_points(@event.start, prev_value, @event.start, value)
    @vertical_line.show
    @horizontal_line.set_points(@event.start, value, next_start, value)
    @horizontal_line.show
    @box.set_x(@event.start)
    @box.set_size(next_start - @event.start, size + 1)
    @box.set_y(if value < center
                 center-size
               else
                 center
               end)
    @box.show
  end
end

######################################################################

#TODO: Remove
class RankedItemList
  def initialize(threshold)
    @threshold = threshold
    @visible = false
    @items = []
  end
  def add_item(item)
    @items.push(item)
  end
  def update(value)
    if value >= @threshold and not @visible
      @visible = true
      @items.each{ |i| i.show }
    elsif value < @threshold and @visible
      @visible = false
      @items.each{ |i| i.hide }
    end
  end
end

module GridCanvas
  attr_reader :length
  def horizontal_scale_factor
    1
  end
  def vertical_scale_factor
    1
  end
  def setup_grid
    @horizontal_ranks = []
    @vertical_ranks = []
    @grid_pens = [[400,2],[300,0],[150,0]].collect do |d, w|
      Qt::Pen.new(background_color.dark(d), w)
    end
  end
  def update_ranks(h, v)
    if @horizontal_ranks
      #print "%f, %f\n" % [h, v]
      @horizontal_ranks.each{ |r| r.update(h) }
      @vertical_ranks.each{ |r| r.update(v) }
    end
  end
end

module HorizontalCanvas
  include GridCanvas
  def setup_horizontal_grid
    @horizontal_grid = true
    @track.sequence.play_cursor.add_view(self)
    # @track.sequence.play_cursor.add_view(self)
    # ppqn = @track.sequence.ppqn
    # @track.sequence.tempo_track.time_signatures.each do |time_signature|
    #   n = time_signature.n
    #   d = time_signature.d
    #   ranks = [ppqn*n*4/d, ppqn, ppqn/d]
    #   # ranks.each do |n|
    #   #   threshold = ppqn.to_f / n / 24
    #   #   #print "%f\n" % threshold
    #   #   @horizontal_ranks.push(RankedItemList.new(threshold))
    #   # end
    #   start = time_signature.start
    #   stop = time_signature.next_start
    #   (start...stop).step(ranks.last) do |n|
    #     line = Qt::CanvasLine.new(self)
    #     line.set_points(n, 0, n, @height)
    #     ranks.each_with_index do |rank, index|
    #       if (n-start) % rank == 0
    #         line.set_pen(@grid_pens[index])
    #         line.set_z(-index)
    #         line.show
    #         # @horizontal_ranks[index].add_item(line)
    #         break
    #       end
    #     end
    #   end
    # end
  end
  def maybe_draw_horizontal_grid(painter, clip)
    return unless @horizontal_grid
    # TODO:
    
    # ppqn = @track.sequence.ppqn
    # @track.sequence.tempo_track.time_signatures.each do |time_signature|
    #   n = time_signature.n
    #   d = time_signature.d
    #   ranks = [ppqn*n*4/d, ppqn, ppqn/d]
    #   # ranks.each do |n|
    #   #   threshold = ppqn.to_f / n / 24
    #   #   #print "%f\n" % threshold
    #   #   @horizontal_ranks.push(RankedItemList.new(threshold))
    #   # end
    #   start = time_signature.start
    #   stop = time_signature.next_start
    #   (start...stop).step(ranks.last) do |n|
    #
    #
    #     ranks.each_with_index do |rank, index|
    #       if (n-start) % rank == 0
    #         line.set_pen(@grid_pens[index])
    #
    #
    #
    #         break
    #       end
    #     end
    #   end
    # end
  end
end

module VerticalCanvas
  include GridCanvas
  attr_reader :height
  def setup_vertical_grid
    @vertical_grid = true
    # ranks = [@height / 2, @height / 4, @height / 16]
    # ranks.each do |n|
    #   threshold = 12.0 / n
    #   #print "%f\n" % threshold
    #   @vertical_ranks.push(RankedItemList.new(threshold))
    # end
    # (0..@height+1).step(ranks.last) do |n|
    #   line = Qt::CanvasLine.new(self)
    #   line.set_points(0,n,length,n)
    #   ranks.each_with_index do |rank, index|
    #     if n % rank == 0
    #       line.set_pen(@grid_pens[index])
    #       line.set_z(-index)
    #       @vertical_ranks[index].add_item(line)
    #       break
    #     end
    #   end
    # end
  end
  def maybe_draw_vertical_grid(painter, clip)
    return unless @vertical_grid
  end
end

######################################################################

class Lane < Qt::Canvas
  include HorizontalCanvas
  include VerticalCanvas

  def initialize(track, *params)
    super()
    retune(32)
    @track = track
    lane_init(*params)
    resize(length, height)
    setup_grid
    setup_horizontal_grid
    setup_vertical_grid
  end
  def length
    @track.sequence.length
  end
  def view(parent)
    LaneView.new(self, parent)
  end
  def drawBackground(painter, clip)
    super
    maybe_draw_horizontal_grid(painter, clip)
  end
  def drawForeground(painter, clip)
    # print "%s, %s\n" % [painter, clip.left]
    # painter.set_world_x_form(false)
    # painter.draw_text(painter.world_matrix.map_rect(clip), AlignCenter, 'moj')
  end
end

NOTE_LANE_COLOR = color(360-110)
BLACK_NOTE_BRUSH = Qt::Brush.new(NOTE_LANE_COLOR.dark(125))

class NoteLane < Lane
  def lane_init
    @track.add_note_lane(self)
    @height = 128+1
    set_background_color(NOTE_LANE_COLOR)
  end
  def add_note(note)
    LaneNote.new(note, self)
  end
  def setup_vertical_grid
    # 128.times do |n|
    #   if [1,3,6,8,10].member?(n % 12)
    #     box = Qt::CanvasRectangle.new(0, n, length, 2, self)
    #     box.set_pen(NO_PEN)
    #     box.set_brush(BLACK_NOTE_BRUSH)
    #     box.set_z(-3)
    #     box.show
    #   end
    #   line = Qt::CanvasLine.new(self)
    #   line.set_points(0,n,length,n)
    #   line.set_pen(@grid_pens[2])
    #   line.set_z(-2)
    #   line.show
    # end
  end
  def make_vertical_ruler
    ClaviatureRuler.new()
  end
  def make_vertical_zoomer
    KeyPitchZoomer.new
  end
end

VELOCITY_LANE_COLOR = color(0)

class VelocityLane < Lane
  def lane_init
    @track.add_note_lane(self)
    @height = 128+1
    set_background_color(VELOCITY_LANE_COLOR)
  end
  def add_note(note)
    LaneNoteVelocity.new(note, self)
  end
  def make_vertical_ruler
    ValueRuler.new((0..127), VELOCITY_LANE_COLOR)
  end
  def make_vertical_zoomer
    VerticalAutoZoomer.new
  end
end

#TODO: Views of pitch bend lanes are very slow.
class ControllerLane < Lane
  attr_reader :controller
  def lane_init(controller)
    @controller = controller
    @track.add_controller_lane(self)
    range = controller.range
    @height = @controller.range.last - @controller.range.first + 2
    set_background_color(CONTROLLER_LANE_COLOR)
  end
  def add_controller(c)
    ControllerLaneEvent.new(c, self)
  end
  def make_vertical_ruler
    ValueRuler.new(controller.range, CONTROLLER_LANE_COLOR)
  end
  def make_vertical_zoomer
    VerticalAutoZoomer.new
  end
end

######################################################################

module ZoomableView
  attr_reader :canvas
  def horizontal_scale
    canvas.horizontal_scale_factor
  end
  def vertical_scale
    canvas.vertical_scale_factor
  end
  def update_zoom
    matrix = Qt::WMatrix.new
    h, v = [horizontal_scale, -vertical_scale]
    matrix.scale(h, v)
    #print "%f\n" % v
    matrix.translate(0, -(canvas.height - 1.0))
    set_world_matrix(matrix)
    canvas.update_ranks(h, -v)
  end
end

AUTOSCROLL_MARGIN = 32

module HorizontalView
  include ZoomableView
  def horizontal_zoomer=(zoomer)
    @horizontal_zoomer = zoomer
    zoomer.add_view(self)
    update_zoom
  end
  def horizontal_scale
    if @horizontal_zoomer
      @horizontal_zoomer.scale_impl * @canvas.horizontal_scale_factor
    else
      1
    end
  end
  def horizontal_scroll(val)
    #print "hscroll %s: %d\n" % [self, val]
    #fail if val == 0
    set_contents_pos(val, contents_y)
  end
  def absolute_cursor_x(cursor)
    m = world_matrix
    m.m11 * cursor.time + m.dx
  end
  def relative_cursor_x(cursor)
    absolute_cursor_x(cursor) - contents_x
  end
  def cursor_visible?(cursor)
    x = relative_cursor_x(cursor)
    return x >= AUTOSCROLL_MARGIN && x < visible_width - AUTOSCROLL_MARGIN
  end
end

module VerticalView
  include ZoomableView
  def vertical_zoomer=(zoomer)
    @vertical_zoomer = zoomer
    zoomer.add_view(self)
    update_zoom
  end
  def vertical_scale
    if @vertical_zoomer
      @vertical_zoomer.scale_impl * @canvas.vertical_scale_factor
    else
      1
    end
  end
  def vertical_scroll(val)
    set_contents_pos(contents_x, val)
  end
end

######################################################################

class Zoomer < Qt::Object
  attr_reader :zoom
  slots 'zoom=(int)'
  def initialize
    super
    @zoom = default_zoom
    @views = []
  end
  def add_view(view)
    @views.push(view)
  end
  def zoom=(val)
    @zoom = val
    @views.each{ |v| v.update_zoom }
  end
  def zoom_range
    (1..100)
  end
  def default_zoom
    50
  end
  def scale_impl
    #0.1 * Math.log10(100 - @zoom+1) + 0.01
    1.0 - @zoom / 101.0
  end
  def zoom_slider?
    true
  end
  def auto_zoom?
    not zoom_slider?
  end
  def update_zoom
  end
  def slider(parent)
    result = Qt::Slider.new(zoom_range.first, zoom_range.last, 1, default_zoom, orientation, parent)
    result.set_focus_policy(Qt::Widget::NoFocus)
    connect(result, SIGNAL('valueChanged(int)'), self, SLOT('zoom=(int)'))
    return result
  end
end

class HorizontalZoomer < Zoomer
  #???
  slots 'zoom=(int)'
  def orientation
    Qt::Horizontal
  end
end

class VerticalZoomer < Zoomer
  #???
  slots 'zoom=(int)'
  def zoom_range
    (1..100)
  end
  def default_zoom
    8
  end
  def scale_impl
    0.1 * @zoom
  end
  def zoom_slider?
    false
  end
  def orientation
    Qt::Vertical
  end
end

class ControlZoomer < Zoomer
  #???
  slots 'zoom=(int)'
  def zoom_range
    (25..100)
  end
  def default_zoom
    50
  end
  def zoom_slider?
    true
  end
  def orientation
    Qt::Vertical
  end
end

class VerticalAutoZoomer < Zoomer
  #???
  slots 'zoom=(int)', 'update_zoom()'
  def update_zoom
    view = @views.first
    self.zoom = 1.0 * view.height / view.canvas.height if view
  end
  def scale_impl
    @zoom
  end
  def zoom_slider?
    false
  end
end

class KeyPitchZoomer < Zoomer
  #???
  slots 'zoom=(int)'
  def zoom_range
    (3..48)
  end
  def default_zoom
    6
  end
  def scale_impl
    @zoom
  end
  def zoom_slider?
    true
  end
  def orientation
    Qt::Vertical
  end
end

######################################################################

class View < Qt::CanvasView
  slots 'horizontal_scroll(int)', 'vertical_scroll(int)'
  def initialize(canvas, parent)
    super(canvas, parent)
    # HEISENBUG: The canvas seems to be garbage collected sometimes without this:
    @canvas = canvas

    set_frame_shape(NoFrame)
    set_h_scroll_bar_mode(AlwaysOff)
    set_v_scroll_bar_mode(AlwaysOff)
    set_drag_auto_scroll(true)
    # connect(self, SIGNAL('contentsMoving(int,int)'), self, SLOT('ruler_moving(int,int)'))
    view_init
  end
  def polish
    #update_zoom
    #center(0, height * 0.5 * vertical_scale)
  end
  def view_init
  end
  slots 'ruler_moving(int,int)'
  def ruler_moving(foo, y)
    print "%s: Use this slot for something?\n" % self
  end
  def resizeEvent(e)
    super
    @vertical_zoomer.update_zoom if @vertical_zoomer
    update
  end
end

class LaneView < View
  include HorizontalView
  include VerticalView
  # Shouldn't these be inherited?
  slots 'horizontal_scroll(int)', 'vertical_scroll(int)'
  signals 'resized()'
end

######################################################################
#  ____        _
# |  _ \ _   _| | ___ _ __
# | |_) | | | | |/ _ \ '__|
# |  _ <| |_| | |  __/ |
# |_| \_\\__,_|_|\___|_|
#

CLAVIATURE_WIDTH = 48
KEY_HEIGHT = 7*6.0
WHITE_KEY_BRUSH = Qt::Brush.new(Qt::Color.new(255,255,255))
BLACK_KEY_BRUSH = Qt::Brush.new(Qt::Color.new(64,64,64))
# OCTAVE_FONT = Qt::Font.new('sans serif', KEY_HEIGHT)
# OCTAVE_COLOR = Qt::Color.new(0,0,0)
# X_SCALE = 5.0

class ClaviatureRuler < Qt::Canvas
  include VerticalCanvas
  def vertical_scale_factor
    1 / KEY_HEIGHT
  end
  def horizontal_scale_factor
    1 #/ X_SCALE
  end
  def initialize()
    super
    @height = 128*KEY_HEIGHT + 1
    resize(CLAVIATURE_WIDTH*KEY_HEIGHT, @height)
    set_background_color(NOTE_LANE_COLOR)

    128.times do |n|
      box = Qt::CanvasRectangle.new(self)
      if [1,3,6,8,10].member?(n % 12)
        box.set_brush(BLACK_KEY_BRUSH)
        box.set_y(n*KEY_HEIGHT)
        box.set_z(1)
        #box.set_size(CLAVIATURE_WIDTH * X_SCALE * 0.55, KEY_HEIGHT)
        box.set_size(CLAVIATURE_WIDTH * 0.55, KEY_HEIGHT)
      else
        box.set_brush(WHITE_KEY_BRUSH)
        box.set_y(n*KEY_HEIGHT + [0, nil, -12, nil, -24, 6, nil, -6, nil, -18, nil, -30][n % 12])
        box.set_z(0)
        #box.set_size(CLAVIATURE_WIDTH * X_SCALE - 1, KEY_HEIGHT * 12 / 7 + 1)
        box.set_size(CLAVIATURE_WIDTH - 1, KEY_HEIGHT * 12 / 7 + 1)
#         if n % 12 == 0
#           text = Qt::CanvasText.new('C%d' % (n/12 - 2), OCTAVE_FONT, self)
#           text.set_color(OCTAVE_COLOR)
#           text.set_text_flags(Qt::AlignCenter)
#           text.set_x(CLAVIATURE_WIDTH * X_SCALE * 0.775)
#           text.set_y((127-n) * KEY_HEIGHT + 7)
#           text.set_z(1)
#           text.show
#         end
      end
      box.show
    end
  end
  def view(parent)
    ClaviatureRulerView.new(self, parent)
  end
end

class ClaviatureRulerView < View
  include VerticalView
  # Shouldn't these be inherited?
  slots 'horizontal_scroll(int)', 'vertical_scroll(int)'
  signals 'resized()'
  def view_init
    set_maximum_width(CLAVIATURE_WIDTH)
  end
end

######################################################################

VALUE_RULER_WIDTH = CLAVIATURE_WIDTH

class ValueRuler < Qt::Canvas
  include VerticalCanvas
  def initialize(range, color)
    super()
    @range = range
    @length = VALUE_RULER_WIDTH
    @height = @range.last - @range.first + 2
    resize(VALUE_RULER_WIDTH, @height)
    set_background_color(color)

    setup_grid
    setup_vertical_grid
  end
  def view(parent)
    ValueRulerView.new(self, parent)
  end
end

class ValueRulerView < View
  include VerticalView
  # Shouldn't these be inherited?
  slots 'horizontal_scroll(int)', 'vertical_scroll(int)'
  signals 'resized()'
  def view_init
    set_maximum_width(VALUE_RULER_WIDTH)
  end
end

######################################################################

TIME_RULER_HEIGHT = 32
TIME_BACKGROUND_COLOR = Qt::Color.new(255,255,255)

class TimeRuler < Qt::Canvas
  include HorizontalCanvas
  attr_reader :sequence
  def initialize(sequence)
    super()
    @sequence = sequence
    @track = sequence.tempo_track
    @length = sequence.length
    @height = TIME_RULER_HEIGHT
    resize(@length, @height)
    set_background_color(TIME_BACKGROUND_COLOR)

    setup_grid
    setup_horizontal_grid

    line = Qt::CanvasLine.new(self)
    line.set_points(0, 0, @length, 0)
    line.set_pen(@grid_pens[1])
    line.show

    # (@lane.length/96).times do |n|
    #   x = n * 96
    #   line = Qt::CanvasLine.new(self)
    #   rank = (if n % @lane.beats_per_bar == 0
    #             1
    #           else
    #             0
    #           end)
    #   line.set_points(x, [0.8, 0][rank] * TIME_RULER_HEIGHT, x, TIME_RULER_HEIGHT)
    #   line.set_pen(@pens[rank])
    #   line.set_z(0)
    #   line.show
    # end
  end
  def view(parent)
    TimeRulerView.new(self, parent)
  end
end

class TimeRulerView < View
  include HorizontalView
  signals 'seek(int)', 'release_seek(int)'
  # Shouldn't these be inherited?
  slots 'horizontal_scroll(int)', 'vertical_scroll(int)'
  signals 'resized()'
  def view_init
    set_maximum_height(TIME_RULER_HEIGHT)
  end
  def contentsMousePressEvent(evt)
    time = evt.x * inverse_world_matrix.m11
    emit seek(time)
  end
  def contentsMouseMoveEvent(evt)
    time = evt.x * inverse_world_matrix.m11
    emit seek(time)
  end
  def contentsMouseReleaseEvent(evt)
    time = evt.x * inverse_world_matrix.m11
    emit release_seek(time)
  end
end

######################################################################
#  _                   __     ___               ____
# | |    __ _ _ __   __\ \   / (_) _____      _| __ )  _____  __
# | |   / _` | '_ \ / _ \ \ / /| |/ _ \ \ /\ / /  _ \ / _ \ \/ /
# | |__| (_| | | | |  __/\ V / | |  __/\ V  V /| |_) | (_) >  <
# |_____\__,_|_| |_|\___| \_/  |_|\___| \_/\_/ |____/ \___/_/\_\

class LaneViewBox < Qt::HBox
  slots 'update_vscrollbar()', 'horizontal_scroll(int)'
  signals 'resized()'
  attr_reader :lane_view
  def initialize(param, parent)
    super(parent)
    box_init(param, parent)
    #set_focus_policy(TabFocus)
  end
  def polish
    update_vscrollbar
    @scroll_vbox.set_maximum_width(@scrollbar.width)
    #vertical_scroll_center
  end
  def box_init(lane, parent)
    @ruler_view = lane.make_vertical_ruler.view(self)
    @lane_view = lane.view(self)

    @scroll_vbox = Qt::VBox.new(self)
    @zoomer = lane.make_vertical_zoomer
    if @zoomer.auto_zoom?
      connect(@lane_view, SIGNAL('resized()'), self, SLOT('update_vscrollbar()'))
    end
    if @zoomer.zoom_slider?
      @slider = @zoomer.slider(@scroll_vbox)
      @slider.set_maximum_height(32)
      connect(@slider, SIGNAL('valueChanged(int)'), self, SLOT('update_vscrollbar()'))
    end
    @scrollbar = Qt::ScrollBar.new(@scroll_vbox)
    @scroll_vbox.set_stretch_factor(@scrollbar, 1)
    [@ruler_view, @lane_view].each do |view|
      #print "%s\n" % view
      #HEISENBUG sometimes triggered here:
      view.vertical_zoomer = @zoomer
      connect(@scrollbar, SIGNAL('valueChanged(int)'), view, SLOT('vertical_scroll(int)'))
    end
  end
  def update_vscrollbar
    @scrollbar.set_max_value([0, @lane_view.contents_height - @lane_view.visible_height].max)
    @scrollbar.set_page_step(@lane_view.visible_height)
    #@scrollbar.set_value(@lane_view.vertical_scroll_bar.value)
    @zoomer.update_zoom
  end
  def ruler_width
    @ruler_view.width
  end
  def vscroll_width
    @scroll_vbox.width
  end
  def horizontal_zoomer=(zoomer)
    @lane_view.horizontal_zoomer = zoomer
  end
  def horizontal_scroll(val)
    @lane_view.horizontal_scroll(val)
  end
  def vertical_scroll_center
    @scrollbar.set_value([0, @lane_view.contents_height - @lane_view.visible_height].max / 2)
  end
  def resizeEvent(e)
    super
    emit resized()
  end
  def vertical_zoom
  end
end

class ControllerLaneViewBox < LaneViewBox
  slots 'vertical_scroll(int)'
  #???
  slots 'update_vscrollbar()', 'horizontal_scroll(int)', 'vertical_zoom(int)'
  signals 'resized()'
  attr_accessor :horizontal_zoomer
  def box_init(track, parent)
    @track = track

    @lane_view = Qt::ScrollView.new(self)
    @lane_view.set_frame_shape(Qt::ScrollView::NoFrame)
    @lane_view.set_resize_policy(Qt::ScrollView::AutoOneFit)
    @lane_view.set_h_scroll_bar_mode(Qt::ScrollView::AlwaysOff)
    @lane_view.set_v_scroll_bar_mode(Qt::ScrollView::AlwaysOff)
    @lanes_widget = Qt::Frame.new(nil)
    @lane_view.add_child(@lanes_widget)

    @lanes_layout = Qt::VBoxLayout.new(@lanes_widget)
    @lanes_layout.set_spacing(5)
    @lane_views = {}

    @scroll_vbox = Qt::VBox.new(self)
    @zoomer = ControlZoomer.new
    @slider = @zoomer.slider(@scroll_vbox)
    @slider.set_maximum_height(32)
    connect(@slider, SIGNAL('valueChanged(int)'), self, SLOT('vertical_zoom(int)'))

    @scrollbar = Qt::ScrollBar.new(@scroll_vbox)
    @scroll_vbox.set_stretch_factor(@scrollbar, 1)
    connect(@scrollbar, SIGNAL('valueChanged(int)'), self, SLOT('vertical_scroll(int)'))

    @zoomer = VerticalAutoZoomer.new
  end
  def polish
    super
    update_zoom
  end
  def update_zoom
    vertical_zoom(@slider.value)
  end
  def add_lane(controller)
    if @lane_views.has_key?(controller)
      @lane_views[controller][2].show
      return
    end
    lane = ControllerLane.new(@track, controller)
    #Qt::Label.new(lane.controller.name, @lanes_vbox)
    hbox = Qt::HBox.new(@lanes_widget)

    @lanes_layout.add_widget(hbox)
    zoomer = lane.make_vertical_zoomer
    ruler_view = lane.make_vertical_ruler.view(hbox)
    ruler_view.vertical_zoomer = zoomer
    lane_view = lane.view(hbox)
    lane_view.vertical_zoomer = zoomer
    lane_view.horizontal_zoomer = @horizontal_zoomer
    @lane_views[controller] = [ruler_view, lane_view, hbox, zoomer]
    hbox.show
    update_zoom
  end
  def remove_lane(controller)
    if @lane_views.has_key?(controller)
      @lane_views[controller][2].hide
    end
  end
  def has_lane?(controller)
    @lane_views.has_key?(controller) and @lane_views[controller][2].visible
  end
  def remove_all_lanes
    @lane_views.each_key{ |c| remove_lane(c) }
  end
  def horizontal_scroll(val)
    @lane_views.each_value{ |r, l, h, z| l.horizontal_scroll(val) }
  end
  def vertical_scroll(val)
    @lane_view.set_contents_pos(@lane_view.contents_x, val)
  end
  def vertical_zoom(val)
    @lane_views.each_value do |r, l, h, z|
      h.set_maximum_height(val)
      h.set_minimum_height(val)
      z.update_zoom
      #r.set_maximum_height(val)
      #r.set_minimum_height(val)
    end
    update_vscrollbar
  end
end
######################################################################
#  ____                                     __     ___
# / ___|  ___  __ _ _   _  ___ _ __   ___ __\ \   / (_) _____      __
# \___ \ / _ \/ _` | | | |/ _ \ '_ \ / __/ _ \ \ / /| |/ _ \ \ /\ / /
#  ___) |  __/ (_| | |_| |  __/ | | | (_|  __/\ V / | |  __/\ V  V /
# |____/ \___|\__, |\__,_|\___|_| |_|\___\___| \_/  |_|\___| \_/\_/
#                |_|

class LaneSet
  attr_reader :track
  def initialize(track, view)
    @track = track
    @view = view
    @splitter = Qt::Splitter.new(Qt::Vertical, @view.splitter)

    @note_lane = add_lane(NoteLane.new(@track))
    show_note_lane(true)
    @velocity_lane = add_lane(VelocityLane.new(@track))
    show_velocity_lane(true)
    @controller_lane = ControllerLaneViewBox.new(@track, @splitter)
    @view.add_lane_view_box(@controller_lane)
    show_controller_lane(false)
  end

  def hide
    @splitter.hide
  end
  def show
    @splitter.show
  end

  def add_lane(lane, &block)
    box = LaneViewBox.new(lane, @splitter, &block)
    @view.add_lane_view_box(box)
    return box
  end
  def show_note_lane(flag)
    @note_lane.set_shown(flag)
    @note_lane_visible = flag
  end
  def note_lane_visible?
    @note_lane_visible
  end
  def show_velocity_lane(flag)
    @velocity_lane.set_shown(flag)
    @velocity_lane_visible = flag
  end
  def velocity_lane_visible?
    @velocity_lane_visible
  end
  def show_controller_lane(flag)
    @controller_lane.set_shown(flag)
    @controller_lane_visible = flag
  end
  def controller_lane_visible?
    @controller_lane_visible
  end

  def add_controller_lane(controller)
    @controller_lane.add_lane(controller)
  end
  def remove_controller_lane(controller)
    @controller_lane.remove_lane(controller)
  end
  def has_controller_lane?(controller)
    @controller_lane.has_lane?(controller)
  end
  def show_controllers_in_track
    @controller_lane.remove_all_lanes
    @track.controllers.each do |c|
      #print "%s\n" % c
      add_controller_lane(c)
    end
  end
end

#TODO: fix lane resizing issue
class SequenceView < Qt::VBox
  slots 'update_hscrollbar()'
  # attr_reader :track
  attr_reader :zoomer, :splitter, :scrollbar, :ruler_view, :current_track
  def initialize(sequence, parent)
    #super
    super(parent)

    @current_track = nil
    @sequence = sequence

    time_ruler = TimeRuler.new(@sequence)

    @zoomer = HorizontalZoomer.new

    vbox = Qt::VBox.new(self)

    hbox = Qt::HBox.new(vbox)
    vbox.set_stretch_factor(hbox, 0)
    @tl_corner = Qt::Widget.new(hbox)
    hbox.set_stretch_factor(@tl_corner, 0)
    @ruler_view = time_ruler.view(hbox)
    @ruler_view.horizontal_zoomer = @zoomer
    hbox.set_stretch_factor(@ruler_view, 1)
    @tr_corner = Qt::Widget.new(hbox)
    hbox.set_stretch_factor(@tr_corner, 0)

    @splitter = Qt::VBox.new(vbox)#Qt::Splitter.new(Qt::Vertical, vbox)
    # @splitter.set_opaque_resize(true)
    vbox.set_stretch_factor(@splitter, 1)

    @bottom_hbox = Qt::HBox.new(vbox)
    vbox.set_stretch_factor(@bottom_hbox, 0)
    @slider = @zoomer.slider(@bottom_hbox)
    @slider.set_maximum_width(100)
    connect(@slider, SIGNAL('valueChanged(int)'), self, SLOT('update_hscrollbar()'))
    @scrollbar = Qt::ScrollBar.new(Qt::Horizontal, @bottom_hbox)
    connect(@scrollbar, SIGNAL('valueChanged(int)'), @ruler_view, SLOT('horizontal_scroll(int)'))
    @bottom_hbox.set_stretch_factor(@scrollbar, 1)
    @br_corner = Qt::Widget.new(@bottom_hbox)
    @bottom_hbox.set_stretch_factor(@br_corner, 0)

    @tracks = {}
    @lane_view_boxes = []
    show_track(@sequence.tracks.first)
  end
  def polish
    lane_view = @lane_view_boxes.first
    r_width = lane_view.vscroll_width
    [@tr_corner, @br_corner].each do |c|
      c.set_minimum_width(r_width)
      c.set_maximum_width(r_width)
    end
    l_width = lane_view.ruler_width
    @tl_corner.set_minimum_width(l_width)
    @tl_corner.set_maximum_width(l_width)
    update_hscrollbar
    @bottom_hbox.set_maximum_height(@scrollbar.height)
  end
  def show_track(track)
    @current_track.hide if @current_track
    (@current_track = (@tracks[track] ||= LaneSet.new(track, self))).show
  end
  def update_hscrollbar
    view = @lane_view_boxes.first.lane_view
    @scrollbar.set_max_value([0,view.contents_width - view.visible_width].max)
    @scrollbar.set_page_step(view.visible_width)
    # @scrollbar.set_value(view.horizontal_scroll_bar.value)
  end
  def add_lane_view_box(lane_view_box)
    @lane_view_boxes.push(lane_view_box)
    lane_view = lane_view_box.lane_view
    lane_view_box.horizontal_zoomer = @zoomer
    #print "%s\n" % lane_view
    lane_view_box.horizontal_scroll(@scrollbar.value)
    connect(@scrollbar, SIGNAL('valueChanged(int)'), lane_view_box, SLOT('horizontal_scroll(int)'))
    connect(lane_view_box, SIGNAL('resized()'), self, SLOT('update_hscrollbar()'))
  end
  def maybe_scroll_to_cursor(cursor, margin = AUTOSCROLL_MARGIN)
    unless @ruler_view.cursor_visible?(cursor)
      if @ruler_view.relative_cursor_x(cursor) < margin || margin != 0
        @scrollbar.set_value(@ruler_view.absolute_cursor_x(cursor) - margin)
      else
        @scrollbar.set_value(@ruler_view.absolute_cursor_x(cursor) + margin - @ruler_view.visible_width)
      end
    end
  end
end

######################################################################

class TrackListItem < KDE::ListViewItem
  attr_reader :track
  def initialize(parent, after, track)
    super(parent, after)
    @track = track
    set_rename_enabled(0, true)
  end
  def text(arg)
    @track.name
  end
end

class TrackListView < KDE::ListView
  def initialize(parent)
    super(parent)
    #add_column('N')
    add_column('Track')
    set_sorting(-1)
    resize_mode = KDE::ListView::AllColumns
  end
  def sequence=(sequence)
    clear
    @sequence = sequence
    last = nil
    @sequence.tracks.each do |track|
      last = TrackListItem.new(self, last, track)
    end
  end
end

######################################################################

class ControllerCheckListItem < Qt::CheckListItem
  def initialize(parent, track_view, controller)
    @track_view = track_view
    @controller = controller
    super(parent, name, Qt::CheckListItem::CheckBox)
    set_state(if @track_view.current_track.has_controller_lane?(@controller) then On else Off end)
  end
  def name
    (if @track_view.current_track.track.has_controller?(@controller)
       '* '
     else
       ''
     end) + @controller.name
  end
  def stateChange(state)
    if state
      @track_view.current_track.add_controller_lane(@controller)
    else
      @track_view.current_track.remove_controller_lane(@controller)
    end
  end
end

class ControllerDialog < KDE::DialogBase
  def initialize(track_view, parent)
    super(parent, 'controller_dialog', true, 'Controllers', Close, Close)
    self.set_minimum_width(550)
    self.set_minimum_height(450)
    @list_view = KDE::ListView.new(self)
    @list_view.add_column('Controller lanes')
    @list_view.resize_mode = KDE::ListView::AllColumns
    track_view.current_track.track.device_controllers.each do |controller|
      ControllerCheckListItem.new(@list_view, track_view, controller)
    end
    set_main_widget(@list_view)
  end
end

######################################################################

TIMER_INTERVAL = 50

class MainWindow < KDE::MainWindow
  slots 'enable_controller_actions()', 'show_note_lane(bool)', 'show_velocity_lane(bool)', 'show_controller_lane(bool)', 'show_controllers_in_track()', 'open_new()', 'open()', 'open_url(const KURL &)', 'controllers()', 'show_track_from_listitem(QListViewItem *)', 'play(bool)', 'stop()', 'timer()', 'seek(int)', 'release_seek(int)'
  def initialize(name)
    super(nil, name)
    @caption = name

    KDE::StdAction.quit(self, SLOT('close()'), actionCollection())
    KDE::StdAction.open_new(self, SLOT('open_new()'), actionCollection())
    KDE::StdAction.open(self, SLOT('open()'), actionCollection())
    @recent = KDE::StdAction.open_recent(self, SLOT('open_url(const KURL &)'), actionCollection())
    @recent.load_entries(KDE::Global.config)

    edit_mode = KDE::ToggleAction.new(i18n('Edit mode'), 'foo', KDE::Shortcut.new(0), nil, nil, actionCollection(), 'edit_mode')
    arrange_mode = KDE::GuiItem.new('Arrange mode')
    edit_mode.set_checked_state(arrange_mode)
    edit_mode.checked = true

    iconset = Qt::IconSet.new(Qt::Pixmap.new(Dir.getwd + "/note_lane.png"))
    @show_note_lane = KDE::ToggleAction.new(i18n('Show &note lane'), iconset, KDE::Shortcut.new('q'), nil, nil, actionCollection(), 'show_note_lane')
    connect(@show_note_lane, SIGNAL('toggled(bool)'), self, SLOT('show_note_lane(bool)'))

    iconset = Qt::IconSet.new(Qt::Pixmap.new(Dir.getwd + "/velocity_lane.png"))
    @show_velocity_lane = KDE::ToggleAction.new(i18n('Show &velocity lane'), iconset, KDE::Shortcut.new('w'), nil, nil, actionCollection(), 'show_velocity_lane')
    connect(@show_velocity_lane, SIGNAL('toggled(bool)'), self, SLOT('show_velocity_lane(bool)'))

    iconset = Qt::IconSet.new(Qt::Pixmap.new(Dir.getwd + "/controller_lane.png"))
    @show_controller_lane = KDE::ToggleAction.new(i18n('Show &controller lane'), iconset, KDE::Shortcut.new('e'), nil, nil, actionCollection(), 'show_controller_lane')
    connect(@show_controller_lane, SIGNAL('toggled(bool)'), self, SLOT('show_controller_lane(bool)'))
    connect(@show_controller_lane, SIGNAL('toggled(bool)'), self, SLOT('enable_controller_actions()'))

    @controllers = KDE::Action.new(i18n('Controllers...'), iconset, KDE::Shortcut.new('r'), self, SLOT('controllers()'), actionCollection(), 'controllers')
    @show_controllers_in_track = KDE::Action.new(i18n('Show controllers in &track'), iconset, KDE::Shortcut.new('t'), nil, nil, actionCollection(), 'show_controllers_in_track')
    connect(@show_controllers_in_track, SIGNAL('activated()'), self, SLOT('show_controllers_in_track()'))

    iconset = Qt::IconSet.new(Qt::Pixmap.new(Dir.getwd + "/snap.png"))
    @snap = KDE::ToggleAction.new(i18n('Snap'), iconset, KDE::Shortcut.new(0), nil, nil, actionCollection(), 'snap')
    @snap.checked = true
    @snap_resolution_combo = Qt::ComboBox.new(self)
    @snap_resolution_combo.insert_string_list(%w[Bar 1/2 1/4 1/8 1/8T 1/16 1/16T 1/32 1/32T 1/64])
    @snap_resolution_combo.set_current_item(5)
    @snap_resolution_combo.set_focus_policy(Qt::Widget::NoFocus)
    @snap_resolution = KDE::WidgetAction.new(@snap_resolution_combo, i18n('Snap resolution'), KDE::Shortcut.new(0), nil, nil, actionCollection(), 'snap_resolution')

    @lcd = Qt::LCDNumber.new(self)
    @lcd.set_segment_style(Qt::LCDNumber::Flat)
    @lcd.set_num_digits(12)
    display_time
    @transport_time = KDE::WidgetAction.new(@lcd, i18n('Time'), KDE::Shortcut.new(0), nil, nil, actionCollection(), 'transport_time')
    @transport_play = KDE::ToggleAction.new(i18n('Play'), 'player_play', KDE::Shortcut.new('Space'), nil, nil, actionCollection(), 'transport_play')
    @transport_play.checked = false
    connect(@transport_play, SIGNAL('toggled(bool)'), self, SLOT('play(bool)'))
    @transport_stop = KDE::Action.new(i18n('Stop'), 'player_stop', KDE::Shortcut.new('z'), self, SLOT('stop()'), actionCollection(), 'transport_stop')
    iconset = Qt::IconSet.new(Qt::Pixmap.new(Dir.getwd + "/follow_play_cursor.png"))
    @follow_play_cursor = KDE::ToggleAction.new(i18n('Follow play cursor'), iconset, KDE::Shortcut.new('f'), nil, nil, actionCollection(), 'follow_play_cursor')
    @follow_play_cursor.checked = true

    #KDE::Action.new(i18n('Reload parameters'), 'reload', KDE::Shortcut.new(0), self, SLOT('reload()'), actionCollection(), 'reload')

    #createGUI
    createGUI(Dir.getwd + "/midimuppui.rc")

    @hbox = Qt::Splitter.new(self)
    set_central_widget(@hbox)
    @track_list_view = TrackListView.new(@hbox)
    connect(@track_list_view, SIGNAL('selectionChanged(QListViewItem *)'), self, SLOT('show_track_from_listitem(QListViewItem *)'))

    open_new

    @timer = Qt::Timer.new
    connect(@timer, SIGNAL('timeout()'), self, SLOT('timer()'))
    @timer.start(TIMER_INTERVAL, true)

  end
  def show_track_from_listitem(item)
    show_track(item.track)
  end
  def show_track(track)
    @view.show_track(track)
    enable_show_actions
  end
  def close_file
    @view.hide if @view
    @sequence = nil
  end
  def sequence=(seq)
    close_file
    @sequence = seq
    $queue.tick_time = 0 if $queue
    @view = SequenceView.new(seq, @hbox)
    connect(@view.ruler_view, SIGNAL('seek(int)'), self, SLOT('seek(int)'))
    connect(@view.ruler_view, SIGNAL('release_seek(int)'), self, SLOT('release_seek(int)'))
    @view.show
    @track_list_view.sequence = @sequence
    @track_list_view.set_selected(@track_list_view.first_child, true)
  end
  def open_new
    set_caption('Unnamed - ' + @caption)
    self.sequence = Sequence.new(true)
  end
  def open
    url = KDE::FileDialog.get_open_URL(nil, '*.mid', self)
    if url.protocol
      if url.protocol != 'file'
        KDE::MessageBox.sorry(self, i18n('Protocol not supported.'))
        return
      end
      open_url(url)
    end
  end
  def open_url(url)
    @recent.add_URL(url)
    @recent.save_entries(KDE::Global.config)
    set_caption(url.file_name + ' - ' + @caption)
    self.sequence = read_smf(File.open(url.path))
  end
  def show_note_lane(flag)
    @view.current_track.show_note_lane(flag)
  end
  def show_velocity_lane(flag)
    @view.current_track.show_velocity_lane(flag)
  end
  def show_controller_lane(flag)
    @view.current_track.show_controller_lane(flag)
  end
  def show_controllers_in_track
    @view.current_track.show_controllers_in_track
  end
  def enable_controller_actions
    [@controllers, @show_controllers_in_track].each do |a|
      a.set_enabled(@show_controller_lane.checked)
    end
  end
  def enable_show_actions
    @show_note_lane.checked = @view.current_track.note_lane_visible?
    @show_velocity_lane.checked = @view.current_track.velocity_lane_visible?
    @show_controller_lane.checked = @view.current_track.controller_lane_visible?
    enable_controller_actions
  end
  def controllers
    dialog ||= ControllerDialog.new(@view, self)
    dialog.exec()
  end
  def play(flag)
    if flag
      @player = SequenceAlsaPlayer.new(@sequence, $port, @sequence.play_cursor.time)
      # print "%d\n" % $seq.drain_output
      @player.queue_more_alsa_events($queue)
      # print "%d\n" % $seq.drain_output
      @timer.start(TIMER_INTERVAL, true)
    else
      midi_stop
    end
  end
  def stop
    if @transport_play.checked
      @transport_play.checked = false
      play(false)
    else
      @sequence.play_cursor.time = 0
      $queue.tick_time = 0
    end
  end
  def timer
    display_time
    if @transport_play.checked
      # TODO: decouple midi sequencing from the qt event loop
      @player.queue_more_alsa_events($queue)
      print "%d\n" % $seq.drain_output
      # $seq.drain_output
    end
    @timer.start(TIMER_INTERVAL, true)
  end
  def display_time
    if $queue and @sequence
      time = $queue.tick_time
      @sequence.play_cursor.time = time
      # print "%s, %s\n" % [@follow_play_cursor, @transport_play]

      #HEISENBUG: More spuriously garbage collected objects
      # /usr/lib/ruby/1.8/Qt/qtruby.rb:1399:in `do_method_missing': method `==' called on terminated object (0xb7c34008) (NotImplementedError)
      #         from ./midimupp.rb:1972:in `method_missing'
      #         from ./midimupp.rb:1972:in `display_time'
      #         from ./midimupp.rb:1958:in `timer'
# 
      # Triggered here:
      if @follow_play_cursor.checked and @transport_play.checked
        @view.maybe_scroll_to_cursor(@sequence.play_cursor)
      end
      @lcd.display(@sequence.bar_beat_pulse_str(time))
    else
      @lcd.display('1: 1.   0')
    end
  end
  def seek(ticks)
    old_pause_state = @seek_pause
    @seek_pause ||= @transport_play.checked
    if @seek_pause and not old_pause_state
      stop
    end
    $queue.tick_time = ticks
    display_time
    @view.maybe_scroll_to_cursor(@sequence.play_cursor, 0)
    # @sequence.play_cursor.time = ticks
  end
  def release_seek(ticks)
    $queue.tick_time = ticks
    if @seek_pause
      print "restart\n"
      @transport_play.checked = true
      @seek_pause = false
      play(true)
    end
  end
end

######################################################################

class Snd::Seq::Queue
  def tick_time=(tick)
    alsa_event = Snd::Seq::Event.new
    alsa_event.source = $port
    alsa_event.set_subs
    alsa_event.set_direct
    alsa_event.set_queue_pos_tick(self, tick)
    $seq.event_output_direct(alsa_event)
  end
end

def midi_init
  $seq = Snd::Seq.open
  $seq.client_name = 'Midimupp'
  $port = $seq.create_simple_port('Sequencer',
                                  Snd::Seq::PORT_CAP_READ | Snd::Seq::PORT_CAP_SUBS_READ |
                                  Snd::Seq::PORT_CAP_WRITE | Snd::Seq::PORT_CAP_SUBS_WRITE,
                                  Snd::Seq::PORT_TYPE_MIDI_GENERIC)
  # TODO
  $port.connect_to(129, 0)
  $port.connect_to(132, 0)

  $queue = $seq.alloc_queue
  # TODO: Find nice workaround? tick_time= doesn't work before the queue has been started.
  $queue.start
  $queue.stop
  $seq.drain_output
end

def midi_stop
  $seq.drop_output
  $queue.stop
  # print "STOP %d\n" % $seq.drain_output
  $seq.drain_output
  # TODO: event_output_direct returns an error, but seems to work. Why?
  16.times do |n|
    alsa_event = Snd::Seq::Event.new
    alsa_event.source = $port
    alsa_event.set_subs
    alsa_event.set_direct
    alsa_event.set_controller(n, 0x78, 0) # All sound off
    # print "ALL SOUND OFF %d\n" % $seq.event_output_direct(alsa_event)
    $seq.event_output_direct(alsa_event)
  end
end

def main
  about = KDE::AboutData.new('midimupp',
                             'Midimupp',
                             '0.0.1',
                             'Some kind of midi application',
                             KDE::AboutData::License_GPL,
                             '(C) 2006 Nicklas Lindgren')
  about.add_author('Nicklas Lindgren',
                   'Developer',
                   'nili@lysator.liu.se')

  KDE::CmdLineArgs.init(ARGV, about)
  a = KDE::Application.new()

  window = MainWindow.new('Midimupp')
  window.resize(800, 600)

  a.main_widget = window
  window.show

  midi_init
  a.exec
  midi_stop
end

main
