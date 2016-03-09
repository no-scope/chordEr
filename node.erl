-module(node).
-export([join/1, join/2, stop/1, locate/2, store/3, delete/2, between/3]).

-define(Stabilize, 1).
-define(Timeout, 10000).
-define(Fix_fingers, 3).
-define(Hash_length, 160).
-define(ReplicationFactor, 5).

%%--------------------------------------------------------------------
%% Node Initiation and Connection.

join(Inc_id) ->
  timer:start(),
  spawn(fun() -> init(Inc_id) end).

join(Inc_id, Peer) ->
  timer:start(),
  spawn(fun() -> init(Inc_id, Peer) end).

stop(Peer) ->
  Peer ! stop.

init(Inc_id) ->
  <<Id:?Hash_length/integer>> = crypto:hash(sha, <<Inc_id>>),
  Predecessor = nil,
  Successor = {Id, self()},
  FingerTable = {0, array:new(?Hash_length+1, {default, Successor})},
  schedule_stabilize(),
  fix_fingers(),
  node(Id, Predecessor, Successor, storage:create(), FingerTable).

init(Inc_id, Peer) ->
  <<Id:?Hash_length/integer>> = crypto:hash(sha, <<Inc_id>>),
  Predecessor = nil,
  Peer ! {find_successor, Id, self()},
  receive
    {successor, Id, Successor} ->
      Successor
  end,
  FingerTable = {0, array:new(?Hash_length+1, {default, Successor})},
  schedule_stabilize(),
  fix_fingers(),
  node(Id, Predecessor, Successor, storage:create(), FingerTable).


store(Key, Value, Peer) ->
  Qref = make_ref(),
  <<Hkey:?Hash_length/integer>> = crypto:hash(sha, Key),
  Peer ! {add, Hkey, {Key,Value}, Qref, self()},
  receive
    {Qref, Ans} ->
      Ans
  after
    ?Timeout ->
      io:format("Time out: no response~n", [])
  end.


locate("*", Peer) ->
  Qref = make_ref(),
  Peer ! {collect_all, Qref, self()},
  receive
    {Qref, All_stores} ->
      All_stores
  end;
locate(Key, Peer) ->
  Qref = make_ref(),
  <<HKey:?Hash_length/integer>> = crypto:hash(sha, Key),
  Peer ! {lookup, HKey, Qref, self()},
  receive
    {Qref, Node, Item} ->
      {Node, Item}
  after
    ?Timeout ->
      io:format("Time out: no response~n", [])
  end.


delete(Key, Peer) ->
  Qref = make_ref(),
  <<HKey:?Hash_length/integer>> = crypto:hash(sha, Key),
  Peer ! {primary_lookup, HKey, Qref, self()},
  receive
    {Qref, RootId, RootPid} ->
      {RootId, RootPid}
  end,
  RootId ! {delete_key, HKey, RootId, ?ReplicationFactor},
  ok.


between(_, From, From) ->
  true;
between(Key, From, To) when From < To ->
  (Key > From) and (Key =< To);
between(Key, From, To) when From > To ->
  (Key > From) or (Key =< To).


between2(_, From, From) ->
  true;
between2(Key, From, To) when From < To ->
  (Key > From) and (Key < To);
between2(Key, From, To) when From > To ->
  (Key > From) or (Key < To).


%%--------------------------------------------------------------------
%% Finger Table Functions

fix_fingers() ->
  timer:send_interval(?Fix_fingers, self(), fix_fingers).


fix_fingers(Id, Successor, {Index, FT}) ->
  case Index+1 > ?Hash_length of
    true ->
      NewIndex = 1;
    false ->
      NewIndex = Index + 1
  end,
  NewFT = fix_finger(Id, Successor, NewIndex, FT),
  {NewIndex, NewFT}.


fix_finger(Id, Successor, Index, FT) ->
  Node = kth_finger(Id, Index),
  find_successor(Node, self(), Id, Successor, FT),
  receive
    {successor, Node, Succ} ->
      Succ
  end,
  array:set(Index, Succ, FT).


kth_finger(Id, K) -> (Id + (1 bsl (K-1))) rem (1 bsl ?Hash_length).


find_successor(Node, Peer, Id, Successor, FT) ->
  {Skey, _} = Successor,
  case between(Node, Id, Skey) of
    true ->
      Peer ! {successor, Node, Successor};
    false ->
      Next = closest_preceding_node(Node, Id, FT),
      Next ! {find_successor, Node, Peer}
  end.


closest_preceding_node(Node, Id, FT) ->
  closest_preceding_node(?Hash_length, Node, Id, FT).

closest_preceding_node(0, _, _, _) ->
  self();
closest_preceding_node(Iter, NodeId, Id, FT) ->
  {Fkey, FPid} = array:get(Iter, FT),
  case between2(Fkey, Id, NodeId) of
    true ->
      FPid;
    false ->
      closest_preceding_node(Iter-1, NodeId, Id, FT)
  end.


%%--------------------------------------------------------------------
%% Node Helper Functions

schedule_stabilize() ->
  timer:send_interval(?Stabilize, self(), stabilize).

stabilize({_, Spid}) ->
  Spid ! {request_predecessor, self()}.


stabilize(Pred, Id, Successor) ->
  {Skey, Spid} = Successor,
  case Pred of
    nil ->
      Spid ! {notify, {Id, self()}},
      Successor;
    {Id, _} ->
      Successor;
    {Skey, _} ->
      Spid ! {notify, {Id, self()}},
      Successor;
    {Xkey, Xpid} ->
      case between(Xkey, Id, Skey) of
	true ->
	  Xpid ! {request_predecessor, self()},
	  Pred;
	false ->
	  Spid ! {notify, {Id, self()}},
	  Successor
      end
  end.


notify({Nkey, Npid}, Id, Predecessor, {_Skey, Spid}, Store) ->
  case Predecessor of
    nil ->
      {KeepStore, ToSend} = update_store(Nkey, Id, Store),
      Npid ! {handover, ToSend},
      Spid ! {update_store, Nkey, Id, ?ReplicationFactor},
      Npid ! {delete_extra_replicas, ?ReplicationFactor-1, {Id, self()}},
      io:format("o neos: ~w ~n", [self()]),
      {{Nkey, Npid}, KeepStore};
    {Pkey, _} ->
      case between(Nkey, Pkey, Id) of
	true ->
	  {KeepStore, ToSend} = update_store(Nkey, Id, Store),
	  Npid ! {handover, ToSend},
	  Spid ! {update_store, Nkey, Id, ?ReplicationFactor-1},
	  {{Nkey, Npid}, KeepStore};
	false ->
	  {Predecessor, Store}
      end
  end.


update_store(Nkey, Id, Store) ->
  case storage:split(Id, Nkey, Store) of
    {Keep, Rest} ->
      Mine = maps:put(Id, Keep, Store),
      if
	Rest =:= #{} ->
	  NewStore = Mine;
	true ->
	  NewStore = maps:put(Nkey, Rest, Mine)
      end,
      {NewStore, Rest};
    not_found ->
      {Store, #{}}
  end.


add(Key, Value, Qref, Client, Id, {Pkey, _}, Successor={_, Spid}, FT, Store) ->
  case between(Key, Pkey, Id) of
    % my Id is RootId for this Key.
    true ->
      Client ! {Qref, self()},
      Spid ! {replicate, Key, Id, ?ReplicationFactor-1, Value},
      storage:add(Id, Key, Value, Store);
    false ->
      find_successor(Key, self(), Id, Successor, FT),
      receive
	{successor, Key, {_, Npid}} ->
	  Npid
      end,
      Npid ! {add, Key, Value, Qref, Client},
      Store
  end.


replicate(Key, RootId, RepFactor, Value, {_, Spid}, Store) ->
  if
    RepFactor > 1 ->
      Spid ! {replicate, Key, RootId, RepFactor-1, Value},
      storage:add(RootId, Key, Value, Store);
    RepFactor =:= 1 ->
      storage:add(RootId, Key, Value, Store);
    RepFactor < 1 ->
      Store
  end.


lookup(Key, Qref, Client, Id, Store, FT) ->
  Result = storage:full_lookup(Key, Store),
  case Result of
    not_found ->
      find_successor(Key, self(), Id, array:get(1, FT), FT),
      receive
	{successor, Key, {_, Npid}} ->
	  Npid
      end,
      if
	Npid =:= self() ->
	  Client ! {Qref, self(), not_exists};
	true ->
	  Npid ! {lookup, Key, Qref, Client}
      end;
    Value ->
      Client ! {Qref, self(), Value}
  end.


primary_lookup(Key, Qref, Client, Id, {Pkey, _}, FT) ->
  case between(Key, Pkey, Id) of
    true ->
      Client ! {Qref, Id, self()};
    false ->
      find_successor(Key, self(), Id, array:get(1, FT), FT),
      receive
	{successor, Key, {_, Npid}} ->
	  Npid
      end,
      Npid ! {primary_lookup, Key, Qref, Client}
  end.


delete_key(Key, RepFactor, RootId, {_, Spid}, Store) ->
  if
    RepFactor > 1 ->
      Spid ! {delete_key, Key, RootId, RepFactor-1},
      storage:delete_key(RootId, Key, Store);
    RepFactor =:= 1 ->
      storage:delete_key(RootId, Key, Store);
    RepFactor < 1 ->
      Store
  end.


%%--------------------------------------------------------------------
%% The main loop for the node proc.

node(Id, Predecessor, Successor, Store, FingerTable = {NextFingerToUpdate, FT}) ->
  receive
    %% A peer needs to know our key Id
    {key, Qref, Peer} ->
      Peer ! {Qref, Id},
      node(Id, Predecessor, Successor, Store, FingerTable);

    %% A new node entered the ring
    {notify, New} ->
      {Pred, Keep} = notify(New, Id, Predecessor, Successor, Store),
      node(Id, Pred, Successor, Keep, FingerTable);

    {successor_status, Pred} ->
      Succ = stabilize(Pred, Id, Successor),
      node(Id, Predecessor, Succ, Store, {NextFingerToUpdate, array:set(1, Succ, FT)});

    {successor, Id, Succ} ->
      node(Id, Predecessor, Succ, Store, {NextFingerToUpdate, array:set(1, Succ, FT)});

    {request_predecessor, Peer} ->
      Peer ! {successor_status, Predecessor},
      node(Id, Predecessor, Successor, Store, FingerTable);

    %% A peer asks us to find the successor of a node
    {find_successor, Node, Peer} ->
      find_successor(Node, Peer, Id, Successor, FT),
      node(Id, Predecessor, Successor, Store, FingerTable);

    stabilize ->
      stabilize(Successor),
      node(Id, Predecessor, Successor, Store, FingerTable);

    fix_fingers ->
      Updated_FT = fix_fingers(Id, Successor, FingerTable),
      node(Id, Predecessor, Successor, Store, Updated_FT);

    %% Predecessor stopped
    {predecessor_stopped, Pred} ->
      node(Id, Pred, Successor, Store, FingerTable);

    %% add an element to the dht
    {add, Key, Value, Qref, Client} ->
      Added = add(Key, Value, Qref, Client,
		  Id, Predecessor, Successor, FT, Store),
      node(Id, Predecessor, Successor, Added, FingerTable);

    {delete_key, Key, RootId, RepFactor} ->
      Removed = delete_key(Key, RepFactor, RootId, Successor, Store),
      node(Id, Predecessor, Successor, Removed, FingerTable);

    {replicate, Key, RootId, RepFactor, Value} ->
      Added = replicate(Key, RootId, RepFactor, Value, Successor, Store),
      node(Id, Predecessor, Successor, Added, FingerTable);

    {delete_extra_replicas, RepFactor, NewNode} ->
      case Predecessor of
	nil ->
	  node(Id, Predecessor, Successor, Store, FingerTable);
	Predecessor ->
	  Predecessor
      end,
      {_Pkey, Ppid} = Predecessor,
      {_Skey, Spid} = Successor,
      case NewNode of
	nil ->
	  ok;
	{_Nkey, Npid} ->
	  io:format("o neos apo mesa: ~w ~n", [Npid]),
	  MyData = storage:get_root_data(Id, Store),
	  if
	    MyData =:= #{} ->
	      ok;
	    true ->
	     Npid ! {handover, Id, MyData}
	  end
      end,
      if
	RepFactor > 1 ->
	  Ppid ! {delete_extra_replicas, RepFactor-1, NewNode},
	  Spid ! {delete_my_storage, Id, ?ReplicationFactor};
	RepFactor =:= 1 ->
	  Spid ! {delete_my_storage, Id, ?ReplicationFactor};
	RepFactor < 1 ->
	  ok
      end,
      node(Id, Predecessor, Successor, Store, FingerTable);

    {delete_my_storage, RootId, RepFactor} ->
      {_Skey, Spid} = Successor,
      if
	RepFactor > 1 ->
	  Spid ! {delete_my_storage, RootId, RepFactor-1},
	  NewStore = Store;
	RepFactor =:= 1 ->
	  NewStore = storage:delete_node_storage(RootId, Store);
	RepFactor < 1 ->
	  NewStore = Store
      end,
      node(Id, Predecessor, Successor, NewStore, FingerTable);

    {update_store, Nkey, RootId, RepFactor} ->
      {_Skey, Spid} = Successor,
      if
	RepFactor > 1 ->
	  {NewStore, _Rest} = update_store(Nkey, RootId, Store),
	  Spid ! {update_store, Nkey, RootId, RepFactor-1};
	RepFactor =:= 1 ->
	  {NStore, _Rest} = update_store(Nkey, RootId, Store),
	  NewStore = maps:remove(Nkey, NStore);
	RepFactor < 1 ->
	  NewStore = Store
      end,
      node(Id, Predecessor, Successor, NewStore, FingerTable);

    %% query for an element in the dht
    {lookup, Key, Qref, Client} ->
      lookup(Key, Qref, Client, Id, Store, FT),
      node(Id, Predecessor, Successor, Store, FingerTable);

    %% finds the primary storage of a key
    {primary_lookup, Key, Qref, Client} ->
      primary_lookup(Key, Qref, Client, Id, Predecessor, FT),
      node(Id, Predecessor, Successor, Store, FingerTable);

    {handover, Bucket} ->
      Merged = storage:add_bucket(Id, Bucket, Store),
      node(Id, Predecessor, Successor, Merged, FingerTable);

    {handover, RootId, Bucket} ->
      Merged = maps:put(RootId, Bucket, Store),
      node(Id, Predecessor, Successor, Merged, FingerTable);

    {collect_all, Qref, Client} ->
      {Skey, Spid} = Successor,
      case Skey of
	Id ->
	  Client ! {Qref, [{Id, self(), Store}]};
	Skey ->
	  Spid ! {collect_all, Qref, Client, Id, [{Id, self(), Store}]}
      end,
      node(Id, Predecessor, Successor, Store, FingerTable);

    {collect_all, Qref, Client, Start, All_stores} ->
      case Start of
	Id ->
	  Client ! {Qref, All_stores};
	Start ->
	  {_, Spid} = Successor,
	  Spid ! {collect_all, Qref, Client, Start, [{Id , self(), Store} | All_stores]}
      end,
      node(Id, Predecessor, Successor, Store, FingerTable);

    {ptsa, Rref, Succ} ->
      {_, Yolo} = Successor,
      Yolo ! {Rref, ok_to_leave},
      node(Id, Predecessor, Succ, Store, {NextFingerToUpdate, array:set(1, Succ, FT)});


    %% stop node gracefully
    stop ->
      {_, SPid} = Successor,
      {Pkey, PPid} = Predecessor,
      SPid ! {handover, Store},
      SPid ! {predecessor_stopped, Predecessor},
      Rref = make_ref(),
      PPid ! {ptsa, Rref, Successor},
      receive
	{Rref, ok_to_leave} ->
	  ok
      end,
      %SPid ! {notify, Predecessor},
      exit(normal);


    %%----------------------------------------------------------------
    %% Debug messages

    %% probe messages for ring connectivity testing

    list_store ->
      io:format("~p ", [Store]),
      node(Id, Predecessor, Successor, Store, FingerTable);

    probe ->
      create_probe(self(), Successor),
      node(Id, Predecessor, Successor, Store, FingerTable);

    {probe, Ref, Nodes, T} ->
      case Ref =:= self() of
	true ->
	  remove_probe(T, Nodes);
	false ->
	  forward_probe(Ref, T, Nodes, Successor)
      end,
      node(Id, Predecessor, Successor, Store, FingerTable);

    %% a simple message to print node state
    state ->
      io:format(' Id : ~w~n Predecessor : ~w~n Successor : ~w~n', [Id, Predecessor, Successor]),
      node(Id, Predecessor, Successor, Store, FingerTable);

    get_ft ->
      io:format('Finger Table: ~w~n', [tl(array:to_list(FT))]),
      node(Id, Predecessor, Successor, Store, FingerTable);

    Msg ->
      io:format('Invalid message received (~w)~n',[Msg]),
      node(Id, Predecessor, Successor, Store, FingerTable)
  end.


%%-------------------------------------------------------------------
%% Probe functions for ring connectivity testing

create_probe(Pid, {_, Spid}) ->
  Spid ! {probe, Pid, [Pid], erlang:timestamp()}.


remove_probe(T, Nodes) ->
  Duration = timer:now_diff(erlang:timestamp(),T),
  Printer = fun(E) -> io:format("~w ",[E]) end,
  lists:foreach(Printer,Nodes),
  io:format("~n Time = ~p ~n",[Duration]).


forward_probe(Ref, T, Nodes, {_,Spid}) ->
  Spid ! {probe,Ref,Nodes ++ [self()],T}.
