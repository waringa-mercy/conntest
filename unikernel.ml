open Lwt.Infix

module Main (S : Tcpip.Stack.V4V6) = struct

  let listen_tcp stack port =
    let callback flow =
      let dst, dst_port = S.TCP.dst flow in
      Logs.info (fun m ->
        m "new tcp connection from IP '%s' on port '%d'"
          (Ipaddr.to_string dst) dst_port);
      S.TCP.read flow >>= function
      | Ok `Eof ->
        Logs.info (fun f -> f "Closing connection!");
        Lwt.return_unit
      | Error e ->
        Logs.warn (fun f ->
          f "Error reading data from established connection: %a"
            S.TCP.pp_error e);
        Lwt.return_unit
      | Ok (`Data b) ->
        Logs.debug (fun f ->
          f "read: %d bytes:\n%s" (Cstruct.length b) (Cstruct.to_string b));
        S.TCP.close flow
    in
    Mirage_runtime.at_exit (fun () ->
      S.TCP.unlisten (S.tcp stack) ~port |> Lwt.return
    );
    S.TCP.listen (S.tcp stack) ~port callback

  let listen_udp stack port =
    let callback ~src:_ ~dst ~src_port:_ data =
      Logs.info (fun m ->
        m "new udp connection from IP '%s' on port '%d'"
          (Ipaddr.to_string dst) port);
      Logs.debug (fun f ->
        f "read: %d bytes:\n%s" (Cstruct.length data) (Cstruct.to_string data));
      Lwt.return_unit
    in
    Mirage_runtime.at_exit (fun () ->
      S.UDP.unlisten (S.udp stack) ~port |> Lwt.return
    );
    S.UDP.listen (S.udp stack) ~port callback

  let try_register_listener ~stack input =
    begin match input with
      | "tcp" :: port :: [] ->
        begin match int_of_string_opt port with
          | Some port -> listen_tcp stack port |> Result.ok
          | None ->
            let msg =
              Fmt.str "Error: try_register_listener: Port '%s' is malformed" port
            in
            Error (`Msg msg)
        end
      | "udp" :: port :: [] ->
        begin match int_of_string_opt port with
          | Some port -> listen_udp stack port |> Result.ok
          | None ->
            let msg =
              Fmt.str "Error: try_register_listener: Port '%s' is malformed" port
            in
            Error (`Msg msg)
        end
      | protocol :: _port :: [] -> 
        let msg = 
          Fmt.str "Error: try_register_listener: Protocol '%s' not supported"
            protocol
        in
        Error (`Msg msg)
      | strs -> 
        let msg = 
          Fmt.str "Error: try_register_listener: Bad format given to --listen. \
                   You passed: '%s'"
            (String.concat ":" strs)
        in
        Error (`Msg msg)
    end
    |> function
    | Ok () -> Lwt.return_unit
    | Error (`Msg msg) ->
      Logs.err (fun m -> m "Error: try_register_listener: %s" msg);
      exit 1

  let log_none msg = function
    | None -> Logs.err (fun m -> m "%s" msg); None
    | Some _ as v -> v

  let result_of_opt msg = function
    | Some v -> Ok v
    | None -> Error (`Msg msg)
  
  let try_initiate_connection ~stack uri_str =
    begin
      let uri = Uri.of_string uri_str in
      let (let*) = Result.bind in
      (* let (let+) x f = Result.map f x in *)
      let* protocol =
        let* protocol_str =
          Uri.scheme uri
          |> result_of_opt (
            Fmt.str "Protocol was not defined in URI '%s'" uri_str
          )
        in
        match protocol_str with
        | "tcp" -> Ok `Tcp
        | "udp" -> Ok `Udp
        | _ -> Error (
          `Msg (Fmt.str "Protocol '%s' is not supported" protocol_str)
        )
      in
      let* ip =
        let* ip_str =
          Uri.host uri
          |> result_of_opt (
            Fmt.str "IP was not present in URI '%s'" uri_str
          )
        in
        Ipaddr.of_string ip_str
      in
      let* port =
        Uri.port uri
        |> result_of_opt (
          Fmt.str "Port was not defined in URI '%s'" uri_str
        )
      in
      let options = Uri.query uri in
      let monitor_bandwidth =
        options |> List.exists (function
          | "monitor-bandwidth", [] -> true
          | _ -> false
        )
      in
      Ok () (*goto goo*)
    end
    |> function
    | Ok () -> Lwt.return_unit
    | Error (`Msg msg) ->
      Logs.err (fun m -> m "Error: try_initiate_connection: %s" msg);
      exit 1
  
  let start stack =
    let stop_t, stop =
      let mvar = Lwt_mvar.create_empty () in
      Lwt_mvar.take mvar, Lwt_mvar.put mvar
    in
    Lwt.async begin fun () -> 
      Key_gen.listen ()
      |> Lwt_list.iter_p (try_register_listener ~stack)
    end;
    Lwt.async begin fun () -> 
      Key_gen.connect ()
      |> Lwt_list.iter_p (try_initiate_connection ~stack)
    end;
    Lwt.pick [ stop_t; S.listen stack ]

end
