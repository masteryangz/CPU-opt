cd ..
source cse148env
cd baseline/mips_cpu
alias r=obj_dir/Vmips_core
alias c=clear
alias m=make
h() {
    cd ../hex_generator ; make ; cd ../mips_cpu
}