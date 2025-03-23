#include <verilated.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <csignal>
#include <unordered_map>
#include <unistd.h>
#include <iomanip>
#include <type_traits>
#include "Vmips_core.h"
#include "verilated_fst_c.h"
#include "Vmips_core__Dpi.h"
#include "memory_driver.h"
#include "memory.h"
#include "simulation.h"

Vmips_core   *top; // Instantiation of module
MemoryDriver *memory_driver;
Memory       *memory;

// *****************************************************
// |   SIMULATOR INPUT                                 |
// *****************************************************
int prediction = 0;
int correct = 0;
int total_btb_used = 0;
int memory_debug         = 0;         // -m
int stream_dump          = 0;         // -d
int stream_print         = 0;         // -p
int stream_check         = 1;         // -s
int _debug_level         = 0;         // -l <LEVEL>
const char *benchmark    = "nqueens"; // -b <BENCHMARK>
const char *output_trace = nullptr;   // -o <FILE>
// *****************************************************
// *****************************************************

// std::string hexfiles_dir = "/home/linux/ieng6/cs148sp22/public";
std::string hexfiles_dir = "..";

vluint64_t main_time = 0; // Current simulation time
// This is a 64-bit integer to reduce wrap over issues and
// allow modulus.  This is in units of the timeprecision
// used in Verilog (or from --timescale-override)

double sc_time_stamp()
{                     // Called by $time in Verilog
    return main_time; // converts to double, to match
                      // what SystemC does
}

volatile std::sig_atomic_t interrupt = 0;
vluint64_t stop_time = 0;

void signal_handler(int signal)
{
    interrupt = signal;
}

std::unordered_map<std::string, unsigned int> stats;

#define T(X) (X*100)
#define DURATION 1000   // default duration
#define S_DURATION "1000" // default duration
#define CYCLES(TIME) (TIME/10) // time to Cycle count

template <typename T>
static constexpr bool is_string_type = std::is_same<
    std::remove_cv_t<std::remove_pointer_t<std::remove_reference_t<T>>>, char
>::value;

static constexpr const char* stage_name_table[] = {
    "Fetch",
    "Decode",
    "Rename",
    "Issue",
    "Commit",
};

struct hex {
    int value;
    
    friend std::ostream& operator<<(std::ostream& os, const hex& hex) {
        return os << '"' << std::hex << std::setw(8) << std::setfill('0')
                  << hex.value << '"' << std::dec;
    }
};

struct PhysReg {
    int index;

    // This is needed so that we are able to
    // use the least significant bit as a 'use' flag
    PhysReg adjust(int n) {
        return { index >> n };
    }
    
    friend std::ostream& operator<<(std::ostream& os, const PhysReg& reg) {
        return os << "\"p" << reg.index << '\"';
    }
};

template <typename T>
struct Trace_Entry {
    char const* key;
    T value;
    bool visible;
};

template <typename T>
Trace_Entry<T> make_entry(char const* key, T const& value, bool visible = true) {
    return {key, value, visible};
}

struct Tracer {
    std::ofstream f;
    int event_count = 0;
    int json_fragment = 0; // only output a JSON fragment
    void create() {
        if (output_trace) f.open(std::string(output_trace) + ".json");
        if (!json_fragment) f << R"({"otherData":{},"traceEvents": [)";
        for (auto&& stage: stage_name_table) {
            f << R"({"cat":"a","dur":1,"name":"DUMMY","ph":"X","pid":")" << output_trace << R"(","tid":")" << stage << R"(","ts":0},)";
        }
    }
    void destroy() {
        if (!f.is_open()) return;
        f.seekp(-1, std::ios_base::cur); // delete last ',' (assumes >0 events)
        f << ' ';
        if (!json_fragment) f << "]}";
        f.close();
        std::cout << "Wrote trace to \"" << output_trace << ".json\"\n";
    }
    template <typename...P>
    void add_json_trace_event(char const* thread, char const* name, uint64_t ts, uint64_t duration, P&&...args) {
        if (event_count >= 100'000) return;
        f << R"({"cat":"write","dur":)" << duration << R"(,"name":")"
          << name
          << R"(","ph":"X","pid":")"
          << output_trace
          << R"(","tid":")"
          << thread
          << R"(","ts":)"
          << T(ts);
        if (sizeof...(P) > 0) {
            f << R"(,"args":{)";
            add_json_trace_event_args(std::forward<P>(args)...);
            f << R"(}},)";
        }
        event_count++;
    }

    template <typename T>
    bool add_json_trace_event_args(Trace_Entry<T> const& entry) {
        if (!entry.visible) return false;
        f << '\"' << entry.key << "\":";
        if (is_string_type<T>) f << '"';
        f << entry.value;
        if (is_string_type<T>) f << '"';
        return true;
    }

    template <typename T, typename...P>
    void add_json_trace_event_args(Trace_Entry<T> const& entry, P&&...rest) {
       if (add_json_trace_event_args(entry)) f << ',';
       add_json_trace_event_args(std::forward<P>(rest)...);
    }

};

Tracer tracer;

void btb_event (int btb_hit){
    if(btb_hit==1){
        ::total_btb_used++;
    }
}

void predictor_event (int prediction, int correct){
    if(prediction==correct){
        ::correct++;
    }
    ::prediction++;
    //std::cout << "hi" << std::endl;
}

typedef struct {
    int type;
    union {
        struct {
            int a, b, c, d, e, f;
        } _input;

        struct {
            hex pc;
            int raw_instruction;
        } fetch;

        struct {
            hex pc;
            Instruction ins;
            Register rw, rs, rt;
            int imm;
        } decode;

        struct {
            hex pc;
            int commit_index;
            PhysReg old; // old mapping for rw
            PhysReg dst;
            PhysReg src1;
            PhysReg src2;
        } rename;

        struct {
            hex pc;
            int commit_index;
            int result, outcome;
        } issue;

        struct {
            hex pc;
            int commit_index;
            PhysReg dst, free;
        } commit;
    };
} Pipeline_Stage_Event;

static_assert(sizeof(Pipeline_Stage_Event) == sizeof(int) * 7);

int debug_level() {
    //if (CYCLES(main_time) < 12607) return 0;
    return _debug_level;
}

const char* alu_ctl_to_string(int alu_ctl) {
    auto op = ALU_Operation(alu_ctl);
    return to_string(op);
}

const char* mips_reg_to_string(int index) {
    auto reg = Register(index);
    return to_string(reg);
}

void log_pipeline_stage(int stage,
    int a, int b, int c, int d, int e, int f
) {
    if (!output_trace) return;
    
    Pipeline_Stage_Event ev = {
        .type = stage,
        ._input = { a, b, c, d, e, f }
    };

    char buffer[32] = {};
    auto stage_name = stage_name_table[stage];

    switch (stage) {
        default: break;
        case 0: {
            auto info = ev.fetch;
            tracer.add_json_trace_event(
                stage_name,
                "F",
                main_time,
                DURATION,
                make_entry("pc", info.pc),
                make_entry("raw_instruction", hex{info.raw_instruction})
            );
            break;
        }
        case 1: {
            auto info = ev.decode;
            tracer.add_json_trace_event(
                stage_name,
                to_string(info.ins),
                main_time,
                DURATION,
                make_entry("pc", info.pc),
                make_entry("rw", to_string(info.rw)),
                make_entry("rs", to_string(info.rs)),
                make_entry("rt", to_string(info.rt)),
                make_entry("imm", info.imm)
            );
            break;
        }
        case 2: {
            auto info = ev.rename;

            if (info.dst.index & 1) // valid?
                snprintf(buffer, sizeof(buffer), "p%i", info.dst.adjust(1).index);
            else
                snprintf(buffer, sizeof(buffer), "I");

            tracer.add_json_trace_event(
                stage_name,
                buffer,
                main_time,
                DURATION,
                make_entry("pc", info.pc),
                make_entry("Commit Index", info.commit_index),
                make_entry("src1", info.src1.adjust(1), info.src1.index & 1),
                make_entry("src2", info.src2.adjust(1), info.src2.index & 1),
                make_entry("old", info.old)
            //  make_entry("dst", info.dst)
            );
            break;
        }
        case 3: {
            auto info = ev.issue;
            snprintf(buffer, sizeof(buffer), "C%i", info.commit_index);
            tracer.add_json_trace_event(
                stage_name,
                buffer,
                main_time,
                DURATION,
                make_entry("pc", info.pc),
                make_entry("Commit Index", info.commit_index),
                make_entry("result", info.result),
                make_entry("outcome", info.outcome)
            );
            break;
        }
        case 4: {
            auto info = ev.commit;
            snprintf(buffer, sizeof(buffer), "C%i", info.commit_index);
            tracer.add_json_trace_event(
                stage_name,
                buffer,
                main_time,
                DURATION,
                make_entry("pc", info.pc),
                make_entry("dst",  info.dst.adjust(1), info.dst.index & 1),
                make_entry("free", info.free.adjust(1), info.free.index & 1),
                make_entry("Commit Index", info.commit_index)
            );
            break;
        }
    }
}

void stats_event(const char *e) {
    std::string s(e);
    stats[s]++;
}

unsigned int instruction_count = 0;

void pc_event(const int pc)
{
    if (stream_print)
        std::cout << "-- EVENT pc=" << std::hex << pc << std::endl;
    if (stream_dump)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".pc.txt");
        static std::ofstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }
        if (stream_dump >= 2)
            f << std::dec << main_time << " ";
        f << std::hex << pc << std::endl;
    }
    if (stream_check)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".pc.txt");
        static std::ifstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }

        unsigned int expected_pc;
        if (!(f >> std::hex >> expected_pc))
        {
            std::cout << "\n!! Ran out of expected pc."
                         "\n!! More instructions are executed than expected"
                         "\n!! Additional pc="
                      << std::hex << pc << std::endl;
            std::raise(SIGINT);
        }
        else if (expected_pc != pc)
        {
            std::cout << "\n!! [" << std::dec << main_time << "] expected_pc=" << std::hex << expected_pc
                      << " mismatches pc=" << pc << std::endl;
            std::raise(SIGINT);
        }
    }
    instruction_count++;
}

unsigned int write_back_count = 0;

void wb_event(const int addr, const int data)
{
    if (stream_print)
        std::cout << "-- EVENT wb addr=" << std::hex << addr
                  << " data=" << data << std::endl;
    if (stream_dump)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".wb.txt");
        static std::ofstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }
        if (stream_dump >= 2)
            f << std::dec << main_time << " ";
        f << std::hex << addr << " " << data << std::endl;
    }
    if (stream_check)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".wb.txt");
        static std::ifstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }

        unsigned int expected_addr, expected_data;
        if (!(f >> std::hex >> expected_addr >> expected_data))
        {
            std::cout << "\n!! Ran out of expected write back."
                         "\n!! More write back are executed than expected"
                         "\n!! Additional write back addr="
                      << std::hex << addr << " data=" << data << std::endl;
            std::raise(SIGINT);
        }
        else if (expected_addr != addr || expected_data != data)
        {
            std::cout << "\n!! [" << std::dec << main_time << "] expected write back mismatches"
                      << "\n!! [" << std::dec << main_time << "] expected addr=" << std::hex << expected_addr
                      << " data=" << expected_data
                      << "\n!! [" << std::dec << main_time << "] actual   addr=" << std::hex << addr
                      << " data=" << data << std::endl;
            std::raise(SIGINT);
        }
    }
    write_back_count++;
}

unsigned int load_store_count = 0;
void ls_event(const int op, const int addr, const int data)
{
    if (stream_print)
        std::cout << "-- EVENT ls op=" << std::hex << op
                  << " addr=" << addr
                  << " data=" << data << std::endl;
    if (stream_dump)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".ls.txt");
        static std::ofstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }
        if (stream_dump >= 2)
            f << std::dec << main_time << " ";
        f << std::hex << op << " " << addr << " " << data << std::endl;
    }
    if (stream_check)
    {
        std::string fname(hexfiles_dir + "/hexfiles/"+ std::string(benchmark) +".ls.txt");
        static std::ifstream f(fname);
        if (!f.is_open())
        {
            std::cerr << "Failed to open file: " << fname << std::endl;
            exit(-1);
        }

        unsigned int expected_op, expected_addr, expected_data;
        if (!(f >> std::hex >> expected_op && f >> expected_addr && f >> expected_data))
        {
            std::cout << "\n!! Ran out of expected load store"
                         "\n!! More load store are executed than expected"
                         "\n!! Additional load store op="
                      << std::hex << op << " addr=" << addr << " data=" << data << std::endl;
            std::raise(SIGINT);
        }
        else if (expected_op != op || expected_addr != addr || expected_data != data)
        {
            std::cout << "\n!! [" << std::dec << main_time << "] expected load store mismatches"
                      << "\n!! [" << std::dec << main_time << "] expected op=" << std::hex << expected_op
                      << " addr=" << expected_addr
                      << " data=" << expected_data
                      << "\n!! [" << std::dec << main_time << "] actual   op=" << std::hex << op
                      << " addr=" << addr
                      << " data=" << data << std::endl;
            std::raise(SIGINT);
        }
    }

    load_store_count++;
}

int main(int argc, char **argv)
{
    std::signal(SIGINT, signal_handler);

    int opt;
    int dump = 0;
    double memory_delay_factor = 1.0;
    while ((opt = getopt(argc, argv, "dmpstf:b:o:l:")) != -1)
    {
        switch (opt)
        {
        case 'd':
            // Dump verilog waves to simx.fst
            dump = 1;
            break;
        case 'm':
            // Print debug info for cpp memory model
            // Repeat to increase verbose level
            memory_debug++;
            break;
        case 'p':
            // Print stream events to stdout
            stream_print = 1;
            break;
        case 's':
            // Skip stream checks
            stream_check = 0;
            break;
        case 't':
            // Trace streams and save to files
            // Repeat to include time in the trace
            stream_dump++;
            break;
        case 'f':
            // Set memory delay factor
            {
                std::stringstream argument(optarg);
                argument >> memory_delay_factor;
            }
            break;
        case 'b':
            benchmark = optarg;
            break;
        case 'o':
            output_trace = optarg;
            break;
        case 'l':
            _debug_level = std::stoi(optarg);
            break;
        default: /* '?' */
            std::cerr << "Usage: " << argv[0] << " [-dmpst] [-b benchmark] [+plusargs]" << std::endl;
            return -1;
        }
    }

    tracer.create(); // create trace if have output file
    Verilated::commandArgs(argc, argv); // Remember args

    top = new Vmips_core; // Create instance
    std::string const hex_file_name (hexfiles_dir + "/hexfiles/" + std::string(benchmark) + ".hex");
    memory = new Memory(hex_file_name.c_str(), memory_delay_factor);
    memory_driver = new MemoryDriver(top, memory);

    VerilatedFstC *tfp;
    if (dump)
    {
        std::cout << "Dumping waveform to simx.fst\n";
        Verilated::traceEverOn(true);
        tfp = new VerilatedFstC;
        top->trace(tfp, 1024);
        tfp->open("simx.fst");
    }

    top->clk = 0;
    top->rst_n = 0;
    memory_driver->drive_reset();

    while (!top->done && !(interrupt && main_time >= stop_time))
    {
        top->clk = !top->clk; // Toggle clock
        if (top->clk)
            memory_driver->consume(main_time);
        if (main_time == 100)
            top->rst_n = 1; // Deassert reset
        top->eval();        // Evaluate model
        if (top->clk)
        {
            memory_driver->drive(main_time);
            memory->process(main_time);
        }
      //  if (main_time % 1000000 == 0)
        //    std::cout << "Time is now: " << main_time << std::endl;
        if (dump)
            tfp->dump(main_time);

        main_time += 5; // Time passes...

        if (interrupt && stop_time == 0)
        {
            stop_time = main_time + 100;
            std::cerr << "\n!! Interrupt raised at time=" << main_time << std::endl
                      << "!! Running additional 10 cycles before terminating at stop_time=" << stop_time << std::endl;
        }
    }

    top->final(); // Done simulating
    delete memory_driver;
    delete top;

    if (dump)
    {
        tfp->close();
    }

    int cycle_count = main_time / 10;
    std::cout << std::dec
              << "\n\nTotal time: " << main_time
              << "\nCycle count: " << cycle_count
              << "\nInstruction count: " << instruction_count
              << "\nCPI: " << (float)cycle_count / instruction_count << " IPC: " << (float)instruction_count / cycle_count << std::endl;

    std::cout << "\n== Stats ===============\n";

    for (const auto &e : stats){
        std::cout << e.first << ": " << e.second << std::endl;
    }
    
    std::cout << "branch predicted correctly: " << correct << std::endl;
    std::cout << "branch: " << prediction << std::endl;

    std::cout << "btb hits: " << total_btb_used << std::endl;

    if (interrupt)
        std::cerr << "\n== ABORTED =============\nSimulation aborted at stop_time=" << main_time << std::endl;

    tracer.destroy();

    {
        printf("%10s %12s %20s %13s %13s %12s %12s %20s %20s\n",
            "Benchmark",
            "Cycle count",
            "Instruction count",
            "CPI",
            "IPC",
            "br_miss",
            "ic_miss",
            "correct prediction",
            "total branch"
        );
        printf("%10s %12u %20u %13f %13f %12d %12d %20d %20d\n",
            benchmark,
            cycle_count,
            instruction_count,
            (float)cycle_count / instruction_count,
            (float)instruction_count / cycle_count,
            stats["br_miss"],
            stats["ic_miss"],
            correct,
            prediction
        );
    }

    delete memory;
}
