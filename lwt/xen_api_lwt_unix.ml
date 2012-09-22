(*
 * Copyright (C) 2012 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

let user_agent = "xen_api_lwt_unix/0.1"

exception No_content_length

exception Http_error of int * string
(** HTTP-layer rejected the request. Assume permanent failure as probably
    the address belonged to some other server. *)

exception No_response
(** No http-level response. Assume ok to retransmit request. *)

type ('a, 'b) result =
	| Ok of 'a
	| Error of 'b

module type IO = sig
	include Cohttp.Make.IO

	val close : (ic * oc) -> unit t

	type address

	val open_connection: address -> ((ic * oc), exn) result t

	val sleep: float -> unit t

	val gettimeofday: unit -> float
end

module Lwt_unix_IO = struct
	include Tmp_cohttp_lwt_unix.IO

	let close (ic, oc) = Lwt_io.close ic >> Lwt_io.close oc

	type address = Unix.sockaddr

	let open_connection address =
		let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in

		try_lwt
			lwt () = Lwt_unix.connect socket address in
			let ic = Lwt_io.of_fd ~close:return ~mode:Lwt_io.input socket in
			let oc = Lwt_io.of_fd ~close:(fun () -> Lwt_unix.close socket) ~mode:Lwt_io.output socket in
			return (Ok (ic, oc))
		with e ->
			return (Error e)

	let sleep = Lwt_unix.sleep

	let gettimeofday = Unix.gettimeofday
end

			

module Make(IO:IO) = struct
	open IO
	type ic = IO.ic
	type oc = IO.oc

	module Request = Cohttp.Request.Make(IO)
	module Response = Cohttp.Response.Make(IO)

	type t = {
		address: address;
		mutable io: (ic * oc) option;
	}

	let of_sockaddr address = {
		address = address;
		io = None;
	}

	let retry timeout delay_between_attempts is_finished f =
		let start = gettimeofday () in
		let rec loop n =
			f () >>= fun result ->
			let time_so_far = gettimeofday () -. start in
			if time_so_far > timeout || is_finished result
			then return result
			else
				sleep (delay_between_attempts time_so_far (n + 1))
				>>= fun () ->
				loop (n + 1) in
		loop 0

	(* Attempt to issue one request every [ideal_interval] seconds.
	   NB if the requests take more than [ideal_interval] seconds to
	   issue then we will retry with no delay. *)
	let every ideal_interval time_so_far next_n =
		let ideal_time = float_of_int next_n *. ideal_interval in
		max 0. (ideal_time -. time_so_far)

	let reconnect (t: t) : ((ic * oc), exn) result IO.t =
		begin match t.io with
			| Some io -> close io
			| None -> return ()
		end >>= fun () ->
		t.io <- None;

		retry 30. (every 1.) (function Ok _ -> true | _ -> false) (fun () -> open_connection t.address)
		>>= function
			| Error e -> return (Error e)
			| Ok io ->
				t.io <- Some io;
				return (Ok io)

let counter = ref 0

	let one_attempt (ic, oc) xml =
		let open Printf in
		let body = Xml.to_string xml in

		let headers = Cohttp.Header.of_list [
			"user-agent", user_agent;
			"content-length", string_of_int (String.length body);
			"connection", "keep-alive";
		] in
		let request = Request.make ~meth:`POST ~version:`HTTP_1_1 ~headers ~body (Uri.of_string "/") in
		Request.write (fun req oc -> Request.write_body req oc body) request oc
		>>= fun () ->
		Response.read ic
		>>= function
			| None ->
				Printf.fprintf stderr "failed to read response\n%!";
				return (Error No_response)
			| Some response ->
				Response.read_body_to_string response ic
				>>= fun result ->
(* for debugging *)
incr counter;
let fd = Unix.openfile (Printf.sprintf "/tmp/response.%d.xml" !counter) [ Unix.O_WRONLY; Unix.O_CREAT ] 0o644 in
let (_: int) = Unix.write fd result 0 (String.length result) in
Unix.close fd;
				match Response.status response with
					| `OK ->
						return (Ok (Xml.parse_string result))
					| s ->
						return (Error (Http_error(Cohttp.Code.code_of_status s, result)))


	let rpc ?(timeout=30.) t xml =
		retry timeout (every 1.) (function Ok _ -> true | _ -> false)
			(fun () ->
				begin match t.io with
					| None -> reconnect t
					| Some io -> return (Ok io)
				end >>= function
					| Error e -> return (Error e)
					| Ok io ->
						one_attempt io xml
			)
end



module M = Make(Lwt_unix_IO)
include M
