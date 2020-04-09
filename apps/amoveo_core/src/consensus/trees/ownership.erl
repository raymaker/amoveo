-module(ownership).
-export([new/7,
         make_tree/1,
         make_proof_batch/2,
         verify_batch/4,
         verify_single/3,
         proof2owner/1,

         pubkey/1,
         pubkey2/1,
         pstart/1,
         pend/1,
         contracts/1,
         priority/1,
         sid/1,
         contract_flip/1,
         
         test/0
        ]).

%we could have a binary merkel tree, where every step of the tree says how the probabilistic value space is divided between the two child branches. Then walking down a path could give you certainty that there is no overlap.
%This option would probably have the least computation and bandwidth requirements.

%We want the same team of validators to be able to manage multiple sortition chains, and use a single merkel root to commit to updates on the different sortition chains simultaneously.

%we also want the ability to assign the same probability space to different people, at the same block height, as long as they take opposite sides of a smart contract. 

%we want to be able to sign the same value to different people at the same height, and have different priorities for each of them.

-record(owner, {pubkey, %pubkey of who owns this probabilistic value space.
                pubkey2, %if it is a channel, then we need 2 pubkeys.
                pstart, %start of the probability space
                pend, %end of the probability space
                priority,
                sortition_id,
                contracts = []
               }).
-record(bounds, {contracts = [],
                 pstart = <<0:256>>,
                 pend = <<-1:256>>,
                 priority_start = 0,
                 priority_end = 255,
                 sid_start = <<0:256>>,
                 sid_end = <<-1:256>>
                }).
-record(tree, {rule, 
               b1, h1, b0, h0}).
new(P, P2, S, E, Pr, SID, Contracts) ->
    32 = size(SID),
    32 = size(S),
    32 = size(E),
    #owner{pubkey = P,
           pubkey2 = P2,
           pstart = S,
           pend = E,
           sortition_id = SID,
           priority = Pr,
           contracts = Contracts
          }.
pubkey(X) -> X#owner.pubkey.
pubkey2(X) -> X#owner.pubkey2.
pstart(X) -> X#owner.pstart.
pend(X) -> X#owner.pend.
contracts(X) -> X#owner.contracts.
sid(X) -> X#owner.sortition_id.
priority(X) -> X#owner.priority.

make_tree(Owners) ->
    Tree = make_tree_sid(Owners),
    add_hashes(Tree).
make_tree_priority(Owners, Bounds) ->
    true = priority_not_zero(Owners),
    Owners2 = 
        lists:sort(
          fun(A, B) ->
                  A1 = A#owner.priority,
                  B1 = B#owner.priority,
                  A1 =< B1 end, Owners),
    Tree1 = make_tree_priority2(Owners2, Bounds).
make_tree_priority2([A], Bounds) -> 
    B = in_bounds(A, Bounds),
    if 
        B -> A;
        true ->
            io:fwrite("in bounds failure\n"),
            io:fwrite(packer:pack({A, Bounds})),
            io:fwrite("\n"),
            1=2
    end;
make_tree_priority2(ListsOwners, Bounds) -> 
    L = length(ListsOwners),
    L2 = L div 2,
    false = (ListsOwners == []),
    OwnerNth = lists:nth(L2, ListsOwners), 
    P = OwnerNth#owner.priority,
    {LA, LB} = lists:split(L2, ListsOwners),
    false = [] == LA,
    false = [] == LB,
    #tree{rule = {priority_before, P},
          b1 = make_tree_priority2(LA, Bounds),
          b0 = make_tree_priority2(LB, Bounds)}.
    
make_tree_sid(Owners) ->
    Owners2 = lists:sort(
                fun(A, B) ->
                        <<A1:256>> = A#owner.sortition_id,
                        <<B1:256>> = B#owner.sortition_id,
                        A1 =< B1 end, Owners),
    ListsOwners = 
        make_lists(fun(X) -> X#owner.sortition_id end, 
                   Owners2),%there are sub-lists each with a unique SID.
    make_tree_sid2(ListsOwners).
priority_not_zero([]) -> true;
priority_not_zero([H|T]) ->
    (not (H#owner.priority == 0)) and
        priority_not_zero(T).
add_hashes(X) when is_record(X, tree) ->
    #tree{
           b0 = B0,
           b1 = B1
         } = X,
    {H0, B02} = add_hashes(B0),
    {H1, B12} = add_hashes(B1),
    X2 = X#tree{
           b0 = B02,
           h0 = H0,
           b1 = B12,
           h1 = H1
          },
    H2 = hash:doit(serialize_tree(X2)),
    {H2, X2};
add_hashes(X) when is_record(X, owner)->
    {hash:doit(serialize(X)), X}.
make_tree_sid2([A]) -> make_tree_prob(A);
make_tree_sid2(ListsOwners) ->
    L = length(ListsOwners),
    L2 = L div 2,
    OwnerNth = hd(lists:nth(L2, ListsOwners)), 
    SID = OwnerNth#owner.sortition_id,
    {LA, LB} = lists:split(L2, ListsOwners),
    false = [] == LA,
    false = [] == LB,
    #tree{rule = {sid_before, SID},
          b1 = make_tree_sid2(LA),
          b0 = make_tree_sid2(LB)}.
make_tree_prob(Owners) ->
    %if people are using smart contracts so that their probability space overlaps with more than one other person's probability space, then divide their ownership objects such that each object is either 100% overlapping with all the others in the same probability space, or else it is 0% overlapping. no partial overlap.
    %make sub-lists of ownership objects that overlap the same probability space, we will divide up contract space in the next step.
    Owners2 = 
        lists:sort(
          fun(A, B) ->
                  <<A1:256>> = A#owner.pstart,
                  <<B1:256>> = B#owner.pstart,
                  A1 =< B1 end, Owners),
    Owners3 = prob_sublists(Owners2),
    true = neg_space_check(Owners3),
    Bounds = #bounds{},
    make_tree_prob2(Owners3, Bounds).
make_tree_prob2([A], Bounds) -> 
    make_tree_contracts(A, Bounds);
make_tree_prob2(ListsOwners, Bounds)->
    L = length(ListsOwners),
    L2 = L div 2,
    Owner = hd(lists:nth(L2, ListsOwners)),
    PE = Owner#owner.pend,
    {LA, LB} = lists:split(L2, ListsOwners),
    Rule = {before, PE},
    #tree{rule = Rule,
          b1 = make_tree_prob2(LA, bounds_update(Rule, Bounds)),
          b0 = make_tree_prob2(LB, bounds_update2(Rule, Bounds))}.
prob_sublists(L) ->
    %break the list into sublists where they probability space for each sublist is 100% overlapping.
    %when necessary, cut ownership contracts into 2 smaller ones.

    Ps = lists:map(fun(X) -> X#owner.pend end, L) ++ lists:map(fun(X) -> X#owner.pstart end, L),
    Ps2 = lists:sort(
            fun(A, B) -> A =< B end,
            Ps),
    Ps3 = remove_repeats(Ps2),
    prob_sublists2(Ps3, L, []).
prob_sublists2([_], _, X) -> lists:reverse(X);
prob_sublists2([A|[B|T]], L, X) ->
    
    %walk forward through the intervals defined by the points in Ps, for each interval find all the ownership contracts for this interval, and chop them up to fit in the interval if needed.

    %L2, remove the completed portion  of the prob space from the leading contracts which may contain it.
    {L2, Batch} = prob_sublists3(A, B, L, [], []),
    %X2, add a list of all the ownership contracts that used this portion of the prob space, chop up contracts as needed.
    if
        Batch == [] ->
            prob_sublists2([B|T], L2, X);
        true ->
            prob_sublists2([B|T], L2, [Batch|X])
    end.
    
prob_sublists3(S, E, [], First, Batch) ->
    {lists:reverse(First), Batch};
prob_sublists3(S, E, [CH|CT], First, Batch) ->
    HOS = CH#owner.pstart,
    HOPE = CH#owner.pend,
    <<EV:256>> = E,
    <<HOSV:256>> = HOS,
    %<<HOPEV:256>> = HOPE,
    if
        EV =< HOSV ->%next contract is outside of the interval we are currently looking at.
            {lists:reverse(First) ++ [CH|CT], 
             Batch};
        E == HOPE ->%next contract matches the interval we are looking at.
            prob_sublists3(
              S, E, CT, First, [CH|Batch]);
        true -> %need to chop
            CB = CH#owner{pend = E},
            CA = CH#owner{pstart = E},
            prob_sublists3(
              S, E, CT, 
              [CA|First], 
              [CB|Batch])
    end.
neg_space_check([]) -> true;
neg_space_check([H|T]) when is_list(H) -> 
    neg_space_check(H) and
        neg_space_check(T);
neg_space_check([H|T]) -> 
    #owner{
            pstart = <<S:256>>,
            pend = <<E:256>>
          } = H,
    (S < E) and neg_space_check(T).
make_tree_contracts(L, Bounds) -> 
    %first get a list of all contract hashes and their inverses that are used for this list.
    CH1 = lists:map(
            fun(X) -> X#owner.contracts end,
            L),
    CH2 = lists:foldr(
            fun(A, B) -> A ++ B end,
            [],
            CH1),
    CH3 = lists:sort(
            fun(<<A:256>>, <<B:256>>) ->
                    A =< B
            end, CH2),
    CH4 = remove_repeats(CH3),
    CH5 = pair_inverses(CH4),
    make_tree_contracts2(L, Bounds, CH5).
make_tree_contracts2([], Bounds, _) -> 
    unused;
make_tree_contracts2([A], Bounds, _) ->
    make_tree_priority([A], Bounds);
make_tree_contracts2(X, Bounds, []) ->
    X2 = lists:foldr(fun(A, B) -> [A|B] end,
                     [],
                     X),
    make_tree_priority(X2, Bounds);
make_tree_contracts2(L, Bounds, [{H1, H2}|Pairs]) ->
    LA = lists:filter(
           fun(X) ->
                   is_in(H1, X#owner.contracts) end,
                 L),
    LB = lists:filter(
           fun(X) ->
                   is_in(H2, X#owner.contracts) end,
           L),
    Neither = lists:filter(
                fun(X) ->
                        not(is_in(X, LA) or
                            is_in(X, LB))
                end,
                L),
    {Ntrue, Nfalse} = contract_space_chop(Neither, H1, H2),
    LA2 = LA ++ Ntrue,
    LB2 = Nfalse ++ LB,
    NC = lists:map(fun(X) -> X#owner.contracts end, LB),
    Rule = {contract, H1},
    B1 = make_tree_contracts2(LA2, bounds_update(Rule, Bounds), Pairs),
    B0 = make_tree_contracts2(LB2, bounds_update2(Rule, Bounds), Pairs),
    if
        (LA2 == []) -> B0;
        (LB2 == []) -> B1;
        true ->
            #tree{rule = Rule,
                  b1 = B1,
                  b0 = B0}
    end.
   
contract_space_chop(Owners, H1, H2) -> 
    A = lists:map(fun(X) ->
                          X#owner{
                            contracts = [H1|X#owner.contracts]
                           }
                  end, Owners),
    B = lists:map(fun(X) ->
                          X#owner{
                            contracts = [H2|X#owner.contracts]
                           }
                  end, Owners),
    {A, B}.
       
pair_inverses([]) -> [];
pair_inverses([H|T]) -> 
    H2 = contract_flip(H),
    T2 = remove_element(H2, T),
    [{H, H2}|pair_inverses(T2)].

remove_element(_, []) -> [];
remove_element(A, [A|T]) -> T;
remove_element(A, [B|T]) -> 
    [B|remove_element(A, T)].

remove_repeats([]) -> [];
remove_repeats([A]) -> [A];
remove_repeats([A|[A|T]]) ->
    remove_repeats([A|T]);
remove_repeats([H|T]) -> 
    [H|remove_repeats(T)].
                              
make_lists(F, []) -> [];
make_lists(F, [H|T]) ->
    lists:reverse(make_lists2(F, F(H), T, [H], [])).
make_lists2(_F, _TID, [], NL, R) -> 
    [lists:reverse(NL)|R];
make_lists2(F, TID, [N|IL], NL, R) ->
    TID2 = F(N),
    if
        TID == TID2 -> 
            make_lists2(F, TID, IL, [N|NL], R);
        true ->
            make_lists2(F, TID2, IL, [N], [lists:reverse(NL)|R])
    end.
            
make_proof_batch(Owner, Tree) when is_record(Tree, tree) ->
    #tree{
           b1 = Branch1,
           b0 = Branch0
         } = Tree,
    Direction = contract_batch_direction(Tree, Owner),
    T2 = Tree#tree{b1 = 0, b0 = 0},
    case Direction of
        one -> T2#tree{b1 = make_proof_batch(Owner, Branch1)};
        zero -> T2#tree{b0 = make_proof_batch(Owner, Branch0)};
        both -> T2#tree{b0 = make_proof_batch(Owner, Branch0),
                        b1 = make_proof_batch(Owner, Branch1)}
    end;
make_proof_batch(_, Owner2) -> Owner2.

no_overlap(A, B) ->
    %if this returns true, then contracts A and B do not overlap in the 2D ((probability space) X (contract space)) plane
    %Used to make sure that for a given part of the value you own in the sortition chain, no one new has been put in line to own it.
    #owner{
         pstart = <<Astart:256>>,
         pend = <<Aend:256>>,
         contracts = AC
        } = A,
    #owner{
            pstart = <<Bstart:256>>,
            pend = <<Bend:256>>,
            contracts = BC
          } = B,
    io:fwrite("in no overlap\n"),
    io:fwrite(packer:pack({Aend, Bstart, Bend, Astart, AC, BC})),
    (Aend < Bstart) or
        (Bend < Astart) or
        no_overlap2(AC, BC).
no_overlap2([], _) -> false;
no_overlap2([H|T], BC) -> 
    H2 = contract_flip(H),
    B = is_in(H2, BC),
    if
        B -> true;
        true -> no_overlap2(T, BC)
    end.
   
intersection(A, B) -> 
    %this should calculate the intersection with bounds, not between 2 ownership objects.
    #owner{
            pstart = <<Astart:256>>,
            pend = <<Aend:256>>,
            sortition_id = <<SID:256>>,
            priority = Priority,
            contracts = AC
          } = A,
    #bounds{
             pstart = <<Bstart:256>>,
             pend = <<Bend:256>>,
             sid_start = <<SidStart:256>>,
             sid_end = <<SidEnd:256>>,
             priority_start = PriorityStart,
             priority_end = PriorityEnd,
             contracts = BC
           } = B,
    %verify that priority is inside the bounds
    if
        (Priority == 0) -> ok;
        true ->
            true = Priority >= PriorityStart,
            true = Priority =< PriorityEnd
    end,
    %verify that SID is inside the bounds
    true = SID >= SidStart,
    true = SID =< SidEnd,
    %verify that the contract space does intersect.
    AC2 = lists:map(fun(X) -> contract_flip(X) end,
                    AC),
    true = lists:foldr(fun(X, A) -> not(is_in(X, BC)) and A end,
                       true,
                       AC2),

    %calculate new probabilistic slice.
    Start = max(Astart, Bstart),
    End = min(Aend, Bend),
    true = Start < End,

    A#owner{
      pstart = <<Start:256>>,
      pend = <<End:256>>,
      contracts = remove_repeats(AC ++ BC)
     }.
                            
    
is_subset(A, B) ->
    %If you own B, then you also own A.
    %given 2 ownership objects, if value is owned by A, it is also owned by B.
    %also checks that both objects have the same owner.
    %given some value you currently own, this is a way to check that the portion you want to spend is also owned by you.
    #owner{
           pubkey = P1,
           pubkey2 = P2,
           pstart = <<Astart:256>>,
           pend = <<Aend:256>>,
           priority = Pr1,
           sortition_id = SID,
           contracts = AC
          } = A,
    #owner{
            pubkey = P1,
            pubkey2 = P2,
            pstart = <<Bstart:256>>,
            pend = <<Bend:256>>,
            priority = Pr2,
            sortition_id = SID2,
            contracts = BC
          } = B,
    PC = case {Pr1, Pr2} of
             {0, _} -> true;
             {X, X} -> true;
             _ -> false
         end,
    PC 
        and (SID == SID2) 
        and (Astart >= Bstart) 
        and (Aend =< Bend) 
        and all_in(BC, AC).

get_leaves(X) when is_record(X, tree) ->
    #tree{
           b0 = B0,
           b1 = B1
         } = X,
    get_leaves(B0) ++ get_leaves(B1);
get_leaves(0) -> [];
get_leaves(X) when is_record(X, owner)-> 
    [X].
  
priority_pubkey_check([], []) -> true;
priority_pubkey_check([], _) -> false;
priority_pubkey_check(
  [{P1, P2, Priority}|T],
  L) -> 
    L2 = lists:filter(
           fun(X) ->
                   #owner{
                pubkey = P1b,
                pubkey2 = P2b,
                priority = Priorityb
               } = X,
                   not((P1 == P1b)
                       and (P2 == P2b)
                       and (Priority == Priorityb))
           end, L),
    priority_pubkey_check(T, L2).
    
verify_single(Ownership, Root, Proof) ->
    #owner{
            priority = Priority,
            pubkey = Pub1,
            pubkey2 = Pub2,
            pstart = <<PStart:256>>,
            pend = <<PEnd:256>>
          }= Ownership,
    true = PStart =< PEnd,
    Who = [{Pub1, Pub2, Priority}],
    false = (0 == Priority),
    Leaves = get_leaves(Proof),
    1 = length(Leaves),
    Root = hash:doit(serialize(Proof)),
    Bounds = #bounds{},
    verify_batch2(Ownership, Bounds, Proof, Who).
    
verify_batch(Ownership0, Root, Proof, Who) ->
    %we are either trying to show that all the leaves are non-overlapping with ownership (Who == []), or that ownership is entirely contained within the leaves (not(Who == []))
    #owner{
            pstart = <<PStart:256>>,
            pend = <<PEnd:256>>
          } = Ownership0,
    true = PStart =< PEnd,
    Ownership = Ownership0#owner{priority = 0},
    Root = hash:doit(serialize(Proof)),
    Bounds = #bounds{},
    case Who of
        [] -> verify_batch2(Ownership, Bounds, Proof, Who);
        _ ->
            Leaves = get_leaves(Proof),
            Checks = lists:map(
                       fun(X) -> 
                               {Pub1, Pub2, Priority} = X,
                               Y = Ownership#owner{ priority = Priority },
                               verify_batch2(Y, Bounds, Proof, [X])
                       end, Who),
            lists:foldr(fun(A, B) -> A and B end,
                        true,
                        Checks) 
                and priority_pubkey_check(Who, Leaves)%check that there are no extra leafs besides what we want to prove.
    end.
verify_batch2(Ownership, Bounds, Proof, Who) 
  when is_record(Proof, owner)->
    B1 = in_bounds(Proof, Bounds),
    B2 = case Who of
             [] ->
                 no_overlap(Ownership, Proof);
             _ ->
                 X = intersection(Ownership, Bounds),
                 io:fwrite("verify_batch2 \n"),
                 io:fwrite(packer:pack(X)),
                 io:fwrite("\n"),
                 %TODO, maybe Who should be a list of pairs matching pubkeys with priorities.
                 is_subset(X, Proof)%this is where we check that he ownership pubkey matches the leaf.
         end,
    B1 and B2;
verify_batch2(Ownership, Bounds, Proof, Kind) ->
    %checks merklization, and the bits of code embeded in the merkle paths.
    #tree{
           rule = Rule,
           h1 = H1,
           h0 = H0,
           b1 = B1,
           b0 = B0
        } = Proof,
    Result = contract_batch_direction(Proof, Ownership),%run_contract(H, Ownership, Dict),
    case Result of
        zero -> 
            H0 = hash:doit(serialize(B0)),
            verify_batch2(Ownership, bounds_update2(Rule, Bounds), B0, Kind);
        one ->
            H1 = hash:doit(serialize(B1)),
            verify_batch2(Ownership, bounds_update(Rule, Bounds), B1, Kind);
        both ->
            H0 = hash:doit(serialize(B0)),
            H1 = hash:doit(serialize(B1)),
            verify_batch2(Ownership, bounds_update2(Rule, Bounds), B0, Kind) and
                verify_batch2(Ownership, bounds_update(Rule, Bounds), B1, Kind)
    end.
            

contract_batch_direction(Tree, Owner) ->
    #owner{
            sortition_id = SID,
            pstart = <<PStart:256>>,
            pend = <<PEnd:256>>,
            priority = P,
            contracts = C
        } = Owner,
    #tree{
           rule = Contract
         } = Tree,
    case Contract of
        {sid_before, <<SID2:256>>} -> 
            <<SID1:256>> = SID,
            if
                SID1 =< SID2 -> one;
                true -> zero
            end;
        {before, <<N:256>>} -> 
            if
                (PEnd =< N) -> one;
                (PStart < N) -> both;
                true -> zero
            end;
        {priority_before, P2} ->
            if
                (P == 0) -> both;
                (P =< P2) -> one;
                true -> zero
            end;
        {contract, C1} ->
            C2 = contract_flip(C1),
            B1 = is_in(C1, C),
            B2 = is_in(C2, C),
            if
                B1 -> one;
                B2 -> zero;
                true -> both
            end
    end.
                    
is_in(X, []) -> false;
is_in(X, [X|_]) -> true;
is_in(X, [_|T]) -> 
    is_in(X, T).
all_in([], _) -> true;
all_in([H|T], L) -> 
    is_in(H, L) and
        all_in(T, L).

in_bounds(Ownership, Bounds) ->
    #owner{
           pstart = <<Ostart:256>>,
           pend = <<Oend:256>>,
           contracts = OC,
           sortition_id = <<SID:256>>,
           priority = Priority
          } = Ownership,
    #bounds{
             priority_start = PriorityStart,
             priority_end = PriorityEnd,
             sid_start = <<SidStart:256>>,
             sid_end = <<SidEnd:256>>,
             pstart = <<Bstart:256>>,
             pend = <<Bend:256>>,
             contracts = BC
           } = Bounds,
    if
        (SID > SidEnd) ->
            io:fwrite("sid too big\n"),
            false;
        (SID < SidStart) ->
            io:fwrite("sid too small\n"),
            false;
        (Priority < PriorityStart) ->
            io:fwrite("priority too small\n"),
            false;
        (Priority > PriorityEnd) ->
            io:fwrite("priority too big\n"),
            false;
        (Bstart > Ostart) ->
            io:fwrite("starts too early\n"),
            io:fwrite(packer:pack([<<Bstart:256>>, <<Ostart:256>>])),
            io:fwrite("\n"),
            io:fwrite(packer:pack([Bstart, Ostart])),
            io:fwrite("\n"),
            false;
        (Oend > Bend) ->
            io:fwrite("ends too late\n"),
            false;
        true ->
            all_in(BC, OC)
    end.
bounds_update({before, <<S:256>>}, 
              Bounds) ->
    S1 = Bounds#bounds.pend,
    S2 = min(S, S1),
    Bounds#bounds{
      pend = <<S2:256>>
     };
bounds_update({contract, CH}, 
              Bounds) ->
    CL1 = Bounds#bounds.contracts,
    B = is_in(CH, CL1),
    case B of
        true -> Bounds;
        false ->
            CL2 = [CH|CL1],
            Bounds#bounds{
              contracts = [CH|CL1]
             }
    end;
bounds_update({sid_before, <<S:256>>}, Bounds) ->
    <<E:256>> = Bounds#bounds.sid_end,
    E2 = min(E, S),
    Bounds#bounds{
      sid_end = <<E2:256>>
     };
bounds_update({priority_before, P}, 
              Bounds) -> 
    P1 = Bounds#bounds.priority_end,
    P2 = min(P, P1),
    Bounds#bounds{
      priority_start = P2
     }.
bounds_update2({before, <<S:256>>}, 
               Bounds) ->
    <<S1:256>> = Bounds#bounds.pstart,
    S2 = max(S, S1),
    Bounds#bounds{
      pstart = <<S2:256>>
     };
bounds_update2({contract, CH},
               Bounds) ->
    CH2 = contract_flip(CH),
    bounds_update(
      {contract, CH2},
      Bounds);
bounds_update2({sid_before, <<S:256>>}, 
               Bounds) -> 
    <<S1:256>> = Bounds#bounds.sid_start,
    S2 = max(S, S1),
    Bounds#bounds{
      sid_start = <<S2:256>>
     };
bounds_update2({priority_before, P}, Bounds) -> 
    P1 = Bounds#bounds.priority_start,
    P2 = max(P, P1),
    Bounds#bounds{
      priority_start = P2
     }.

contract_flip(<<N:1, R:255>>) ->    
    N2 = case N of
             0 -> 1;
             1 -> 0
         end,
    <<N2:1, R:255>>.

serialize_tree(T) ->
    #tree{
           rule = {Type, C0},
           h0 = H0,
           h1 = H1
         } = T,
    {C, A} = case Type of
                 sid -> {C0, 1};
                 before -> {C0, 2};
                 priority -> {<<C0:8>>, 3};
                 sid_before -> {C0, 4};
                 priority_before -> {<<C0:8>>, 5};
                 contract -> {C0, 6}
        end,
                   
    <<C/binary, H0/binary, H1/binary, A:8>>.

serialize(X) when is_record(X, tree)->
    serialize_tree(X);
serialize(X) ->
    PS = constants:pubkey_size(),
    HS = constants:hash_size(),
    #owner{
            pubkey = P,
            pubkey2 = P2,
            pstart = S,
            pend = E,
            priority = Pr,
            sortition_id = SID,
            contracts = C
      } = X,
    PS = size(P),
    PS = size(P2),
    32 = size(S),
    32 = size(E),
    HS = size(SID),
    CB = serialize_contracts(C, <<>>),
    <<P/binary,
      P2/binary,
      S/binary,
      E/binary,
      SID/binary,
      CB/binary,
      Pr:8>>.
serialize_contracts([], X) -> X;
serialize_contracts([H|T], X) ->
    <<_:256>> = H,
    X2 = <<X/binary, H/binary>>,
    serialize_contracts(T, X2).
   
tree_to_leaves(T) when is_record(T, tree) -> 
    #tree{b0 = B0,
          b1 = B1} = T,
    tree_to_leaves(B0) ++ tree_to_leaves(B1);
tree_to_leaves(X) when is_record(X, owner)-> 
    [X].

proof2owner(T) when is_record(T, owner) -> T;
proof2owner(T) when is_record(T, tree) ->
    #tree{
           b1 = B1,
           b0 = B2
         } = T,
    B3 = if
             B1 == 0 -> B2;
             B2 == 0 -> B1
         end,
    proof2owner(B3).

test() ->
    SID = hash:doit(1),
    SID2 = hash:doit(2),
    <<Max:256>> = <<-1:256>>,
    M1 = Max div 6,
    M2 = M1 + M1,
    M3 = M2 + M1,
    M4 = M2 + M2,
    M5 = M2 + M3,
    M6 = Max - 1,
    H1 = hash:doit(1),
    H2 = hash:doit(2),
    X1 = new(keys:pubkey(),
             <<0:520>>,
             <<0:256>>,
             <<M3:256>>,
             1,
             SID,
             [H1]),
    X2 = new(keys:pubkey(),
             <<0:520>>,
             <<M3:256>>,
             <<M4:256>>,
             1,
             SID,
            [H1, H2]),
    H2b = contract_flip(H2),
    H1b = contract_flip(H1),
    X3 = new(keys:pubkey(),
             <<0:520>>,
             <<M4:256>>,
             <<M5:256>>,
             1,
             SID,
            [H2b]),
    X4 = new(keys:pubkey(),
             <<0:520>>,
             <<M5:256>>,
             <<M6:256>>,
             1,
             SID,
            []),
    X5 = new(keys:pubkey(),
             <<0:520>>,
             <<0:256>>,
             <<M6:256>>,
             1,
             SID2,
            []),
    SID3 = hash:doit(3),
    X6 = new(keys:pubkey(),
             <<0:520>>,
             <<0:256>>,
             <<M6:256>>,
             2,
             SID,
            [H1]),
    %L2 = [X1, X6],
    L2 = [X1, X2, X3, X4, X5, X6],
    %L2 = [X1, X2, X6],
    {Root, T} = make_tree(L2),
    X9 = new(keys:pubkey(),
             <<0:520>>,
             <<(M3-10):256>>,
             <<(M3+10):256>>,
             0,
             SID,
             [H1b]),
    Proof9 = make_proof_batch(X9, T),
    true = verify_batch(X9, Root, Proof9, []),
    X10 = new(keys:pubkey(),
             <<0:520>>,
             <<(M4):256>>,
             <<(M4+10):256>>,
             1,
             SID,
             [H2b, H1b]),
    Proof10 = make_proof_batch(X10, T),
    true = verify_single(X10, Root, Proof10),
    X11 = new(keys:pubkey(),
             <<0:520>>,
             <<(M4):256>>,
             <<(M4+10):256>>,
             0,
             SID,
             [H1, H2]),
    Proof11 = make_proof_batch(X11, T),
    io:fwrite("verify batch 11 \n"),
    true = verify_batch(X11, Root, Proof11, [{keys:pubkey(), <<0:520>>, 2}]),

    
    success.
    