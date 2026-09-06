# Jane-Street-Puzzle-August-2026
Custom scripts and Verilog testbenches used for solving the Jane Street puzzle (https://blog.janestreet.com/can-you-reverse-engineer-an-asic/)

The full write-up explaining how these files were created and used is given in the pdf document at the top. It can also be found on a blog (https://davidgarner2026janestreetpuzzle.blogspot.com/2026/09/jane-street-can-you-reverse-engineer.html)

A summary of all the files is given below:

1. Customised layer map table file for “revealing” layer 230:0 on which the “Easter Egg” morse code was written: sky130_fd_pr_main.layermap_200y0_236y1
2. Perl script to convert a SPICE netlist into a Verilog netlist: spice2verilog_9t_composite.pl
3. “Makefile” for compiling all the open-source standard cells into a single file for inclusion as a library in xcelium. This needs to sit at the top of the standard-cell installation hierarchy: make_sky130_f.csh
4. Verilog testbench for digital simulations of the puzzle Verilog: puzzle_tb7inoutfile.v
5. Perl script to generate valid Star Battle puzzle solutions for an 11x11 grid: starbattle_vectors_general.pl
6. Simple input and resulting output files with the solution input vector “topped and tailed” to give 0000…,0101…,solution,1010,1111: input_vectors_solution_toptail20260821a.txt and output_strings_solution_toptail20260821a.txt
