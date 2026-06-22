OUTPUT OF APB
<img width="966" height="496" alt="Screenshot 2026-06-17 154000" src="https://github.com/user-attachments/assets/d95215a1-07a8-4d54-b884-07685e386a11" />

# APB Protocol (Advanced Peripheral Bus)

## Overview
APB is a simple, low-bandwidth master-slave bus interface designed for peripherals and slow control registers in ARM AMBA SoCs. It provides a straightforward protocol for connecting low-speed peripherals.

## Key Features
- **Simple Protocol**: Easy to implement and understand
- **Low Bandwidth**: Suitable for control and configuration registers
- **Master-Slave Architecture**: Single master drives transfers to multiple slaves
- **No Pipelining**: Transfers are sequential and synchronous

## Main Signals
- **PADDR**: Address bus (peripheral address)
- **PDATA**: Data bus (read/write data)
- **PWRITE**: Write enable signal
- **PSEL**: Peripheral select
- **PENABLE**: Transfer enable
- **PREADY**: Slave ready signal
- **PRDATA**: Read data from slave

## Basic Transfer
1. Master drives address, write signal, and asserts PSEL
2. Master asserts PENABLE to indicate transfer start
3. Slave samples signals when PENABLE is high
4. Slave asserts PREADY when data is available
5. Data is transferred on the rising clock edge

## Use Cases
- Accessing control registers
- Configuration of peripherals
- Status polling
- Interrupt control
