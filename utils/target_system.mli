(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2017 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Types corresponding to the compiler's target machine. *)

type linux_abi = private
  | SVR4
  | ARM_EABI
  | ARM_EABI_hard_float

type windows_system = private
  | Cygwin
  | Mingw
  | Native

type system = private
  | Linux of linux_abi
  | Windows of windows_system
  | MacOS_like
  | FreeBSD
  | NetBSD
  | OpenBSD
  | Other_BSD
  | Solaris
  | GNU
  | BeOS
  | Unknown

type hardware = private
  | X86_32
  | X86_64
  | ARM
  | AArch64
  | POWER
  | SPARC
  | S390x

type assembler = private
  | GAS_compatible
  | MASM

type machine_width = private
  | Thirty_two
  | Sixty_four

(** The target system of the OCaml compiler. *)
val system : unit -> system

(** Whether the target system is a Windows platform. *)
val windows : unit -> bool

(** The hardware of the target system. *)
val hardware : unit -> hardware

(** The assembler being used. *)
val assembler : unit -> assembler

(** The natural machine width of the target system. *)
val machine_width : unit -> machine_width
