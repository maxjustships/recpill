"""Unit tests for the Linux recorder's pure logic (mixer, config, microphone choice). Run: python3 -m unittest discover linux/tests"""
import array
import importlib.machinery
import importlib.util
import math
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_loader("recpill", importlib.machinery.SourceFileLoader("recpill", os.path.join(HERE, "..", "recpill.py")))
rp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rp)

R = 1000  # tiny rate keeps the tests instant


def samples(value, n):
    return array.array("h", [value] * n)


def decode(b):
    a = array.array("h")
    a.frombytes(b)
    return a


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def make_mixer():
    out = bytearray()
    clock = Clock()
    mx = rp.Mixer(out.extend, rate=R, clock=clock)
    return mx, out, clock


class MixerTests(unittest.TestCase):
    def test_two_sources_are_summed(self):
        mx, out, clock = make_mixer()
        a, b = rp.Track(), rp.Track()
        clock.t = 2.0
        mx.add(a, samples(8000, 500))
        mx.add(b, samples(16000, 500))
        mx.flush(0)
        s = decode(bytes(out))
        self.assertEqual(len(s), 2000)
        self.assertEqual(s[100], 0)
        self.assertEqual(s[1499], 0)
        self.assertEqual(s[1500], 24000)
        self.assertEqual(s[1999], 24000)

    def test_sum_is_clipped_not_wrapped(self):
        mx, out, clock = make_mixer()
        a, b = rp.Track(), rp.Track()
        clock.t = 0.1
        mx.add(a, samples(30000, 100))
        mx.add(b, samples(30000, 100))
        mx.flush(0)
        s = decode(bytes(out))
        self.assertEqual(s[50], 32767)
        mx2, out2, clock2 = make_mixer()
        c, d = rp.Track(), rp.Track()
        clock2.t = 0.1
        mx2.add(c, samples(-30000, 100))
        mx2.add(d, samples(-30000, 100))
        mx2.flush(0)
        self.assertEqual(decode(bytes(out2))[50], -32768)

    def test_a_source_that_leaves_does_not_disturb_the_rest(self):
        mx, out, clock = make_mixer()
        gone, stays = rp.Track(), rp.Track()
        clock.t = 0.1
        mx.add(gone, samples(16000, 100))
        mx.add(stays, samples(8000, 100))
        clock.t = 0.2
        mx.add(stays, samples(8000, 100))
        mx.flush(0)
        s = decode(bytes(out))
        self.assertEqual(s[50], 24000)
        self.assertEqual(s[150], 8000)
        self.assertEqual((gone.resyncs, stays.resyncs), (0, 0))

    def test_jitter_is_absorbed_but_big_drift_resyncs(self):
        mx, out, clock = make_mixer()
        t = rp.Track()
        clock.t = 1.0
        mx.add(t, samples(1, 100))
        clock.t = 1.05
        mx.add(t, samples(1, 100))
        self.assertEqual(t.resyncs, 0)
        clock.t = 3.0
        mx.add(t, samples(1, 100))
        self.assertEqual(t.resyncs, 1)

    def test_long_sleep_is_cut_out(self):
        mx, out, clock = make_mixer()
        clock.t = 1.0
        mx.flush(0)
        clock.t = 1000.0
        mx.flush(0)
        self.assertLess(len(out) // 2, 1500)

    def test_margin_is_kept_behind_now(self):
        mx, out, clock = make_mixer()
        clock.t = 3.0
        mx.flush(R)
        self.assertEqual(len(out) // 2, 2000)
        self.assertAlmostEqual(mx.seconds, 2.0)

    def test_ring_buffer_wraps_around(self):
        mx, out, clock = make_mixer()
        t = rp.Track()
        total = 0
        # 20 s of constant audio in 100 ms packets, flushed as we go: far more than the 8 s ring
        for i in range(1, 201):
            clock.t = i * 0.1
            mx.add(t, samples(1000, 100))
            if i % 5 == 0:
                mx.flush(0)
        s = decode(bytes(out))
        self.assertEqual(len(s), 20 * R)
        self.assertEqual(t.resyncs, 0)
        self.assertEqual(sum(1 for v in s if v == 1000), 20 * R - 0, "every sample carries the signal")

    def test_late_packet_older_than_flushed_audio_is_dropped_safely(self):
        mx, out, clock = make_mixer()
        a, b = rp.Track(), rp.Track()
        clock.t = 2.0
        mx.add(a, samples(100, 500))
        mx.flush(0)
        before = len(out)
        b.started, b.pos = True, 100  # claims to be at t=0.1 s, long since written
        mx.add(b, samples(5000, 50))
        mx.flush(0)
        self.assertEqual(len(out), before)  # nothing re-written, no crash


class PickMicTests(unittest.TestCase):
    def test_default_wired_mic_wins(self):
        self.assertEqual(rp.pick_mic("alsa_input.usb", ["alsa_input.usb", "bluez_input.X"], lambda s: True)[0], "alsa_input.usb")

    def test_idle_bluetooth_default_is_not_opened(self):
        name, why = rp.pick_mic("bluez_input.AA", ["bluez_input.AA"], lambda s: False)
        self.assertIsNone(name)
        self.assertIn("idle bluetooth", why)

    def test_idle_bluetooth_default_falls_back_to_wired(self):
        name, _ = rp.pick_mic("bluez_input.AA", ["bluez_input.AA", "alsa_input.pci"], lambda s: False)
        self.assertEqual(name, "alsa_input.pci")

    def test_bluetooth_mic_used_when_a_call_app_has_it(self):
        name, why = rp.pick_mic("bluez_input.AA", ["bluez_input.AA", "alsa_input.pci"], lambda s: True)
        self.assertEqual(name, "bluez_input.AA")
        self.assertIn("call app", why)

    def test_monitor_is_never_a_mic(self):
        name, _ = rp.pick_mic("alsa_output.x.monitor", ["alsa_input.pci"], lambda s: False)
        self.assertEqual(name, "alsa_input.pci")

    def test_no_sources(self):
        self.assertEqual(rp.pick_mic(None, [], lambda s: False)[0], None)

    def test_last_wired_memo_beats_first_in_list(self):
        name, _ = rp.pick_mic("bluez_input.AA", ["alsa_input.a", "alsa_input.b", "bluez_input.AA"], lambda s: False, memo="alsa_input.b")
        self.assertEqual(name, "alsa_input.b")


class MiscTests(unittest.TestCase):
    def test_config_parse(self):
        c = rp.parse_config('\ufeff# c\noutput_dir = "/tmp/my calls"\nMAX_HOURS=2.5\n;x=1\nbroken\n')
        self.assertEqual(c["output_dir"], "/tmp/my calls")
        self.assertEqual(c["max_hours"], "2.5")
        self.assertNotIn("x", c)
        self.assertNotIn("broken", c)

    def test_duration_text(self):
        self.assertEqual(rp.dur(5), "5 s")
        self.assertEqual(rp.dur(65), "1 min 5 s")
        self.assertEqual(rp.dur(3700), "1 h 1 min")

    def test_clip_bytes_little_endian(self):
        b = rp._clip_to_bytes(array.array("i", [1, -1, 40000, -40000]))
        self.assertEqual(list(decode(b)), [1, -1, 32767, -32768])


if __name__ == "__main__":
    unittest.main()
