require 'mkmf'

dir_config('asound')
find_library('asound', 'snd_seq_open')

create_makefile('_asound')
