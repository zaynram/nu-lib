# Functions run after the script, in order; each reports its own changes.
export SBFB_A=0
SBFB_S=top
f0() { :; }
f1() { export SBFB_A=1; export SBFB_F1=yes; SBFB_S1=one; }
f2() { export SBFB_A=2; unset SBFB_S; SBFB_S1=two; local SBFB_L=local; }
