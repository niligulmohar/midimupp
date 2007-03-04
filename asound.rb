require '_asound'

module Snd::Seq
  class << self
    def open
      Snd::Seq::Seq.new
    end
  end
  class Seq
    def create_simple_port(name, caps, type)
      Port.new(self, _create_simple_port(name, caps, type))
    end
    def alloc_queue
      Queue.new(self, _alloc_queue)
    end
    def change_queue_tempo(q, tempo, ev = nil)
      _change_queue_tempo(q, tempo, ev)
    end
    def start_queue(q, ev = nil)
      _start_queue(q, ev)
    end
    def stop_queue(q, ev = nil)
      _stop_queue(q, ev)
    end
    def continue_queue(q, ev = nil)
      _continue_queue(q, ev)
    end
  end
  class Port
    def initialize(seq, n)
      @seq = seq
      @n = n
    end
    def to_int() @n; end
    def connect_to(client, port)
      @seq.connect_to(@n, client, port)
    end
    def connect_from(client, port)
      @seq.connect_from(@n, client, port)
    end
  end
  class Queue
    def initialize(seq, n)
      @seq = seq
      @n = n
    end
    def to_int() @n; end
    def ppq=(ppq)
      @seq.change_queue_ppq(@n, ppq)
    end
    def change_tempo(bpm, ev = nil)
      @seq.change_queue_tempo(@n, 60000000 / bpm, ev)
    end
    def tempo=(bpm)
      change_tempo(bpm)
    end
    def start(ev = nil)
      @seq.start_queue(@n, ev)
    end
    def stop(ev = nil)
      @seq.stop_queue(@n, ev)
    end
    def continue(ev = nil)
      @seq.continue_queue(@n, ev)
    end
    def tick_time
      @seq.queue_get_tick_time(@n)
    end
  end
  # class Event
  #   def to_subscribers=(val)
  #     if not val
  #       raise RuntimeError.new
  #     else
  #       set_subs
  #     end
  #   end
  #   def direct=(val)
  #     if not val
  #       raise RuntimeError.new
  #     else
  #       set_direct
  #     end
  #   end
  # end
end
