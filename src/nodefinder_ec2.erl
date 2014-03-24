%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%% @doc EC2 Erlang node discovery.
%% @end

-module(nodefinder_ec2).

-behaviour(gen_server).

%% external interface
-export([start_link/5,
         discover/1,
         validate_groups/1,
         validate_tags/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type group_input() :: string().
-type tag_input() :: {list(string()) | string(), list(string()) | string()} |
                     list(string()) |
                     string().
-type condition(Value) :: {'AND', list(Value)} | {'OR', list(Value)}.
-type condition_meta(Value) :: condition(condition(condition(Value))).
-type tag() :: condition_meta(tag_input()) | tag_input().
-type group() :: condition_meta(group_input()) | group_input().
-export_type([group/0,
              tag/0]).

-type tag_output() :: list({string(), list(string())}).
-type group_output() :: string().
-type tag_value() :: condition_meta(tag_output()).
-type group_value() :: condition_meta(group_output()).

-include_lib("erlcloud/include/erlcloud.hrl").
-include_lib("erlcloud/include/erlcloud_ec2.hrl").

-record(state,
    {
        ec2_config,
        ec2_instances,
        ec2_tagged_instances,
        groups :: list(group_value()),
        tags :: list(tag_value()),
        tags_filter :: list({key, list(string())} |
                            {value, list(string())}),
        nodes :: list(node()),
        connect :: visible | hidden
    }).

-define(NULL_EXPRESSION, [{'OR', []}]).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

% finds nodes with security group id OR tags (union of both sets)

-spec start_link(AccessKeyID :: string(),
                 SecretAccessKey :: string(),
                 EC2Host :: string(),
                 Groups :: list(group()),
                 Tags :: list(tag())) ->
    {ok, pid()} |
    ignore |
    {error, any()}.

start_link(AccessKeyID, SecretAccessKey, EC2Host, Groups, Tags) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          [AccessKeyID, SecretAccessKey, EC2Host,
                           Groups, Tags], []).

-spec discover(Timeout :: pos_integer()) ->
    ok |
    {error, discover_failed | timeout | noproc | any()}.

discover(Timeout) ->
    try gen_server:call(?MODULE, discover, Timeout)
    catch
        exit:{Reason, _} ->
            {error, Reason}
    end.

-spec validate_groups(Groups :: list(group())) ->
    ok |
    {error, any()}.

validate_groups(Groups) when is_list(Groups) ->
    case preprocess(Groups, group) of
        {ok, _} ->
            ok;
        {error, _} = Error ->
            Error
    end;
validate_groups(_) ->
    {error, invalid_type}.

-spec validate_tags(Tags :: list(tag())) ->
    ok |
    {error, any()}.

validate_tags(Tags) when is_list(Tags) ->
    case preprocess(Tags, tag) of
        {ok, _} ->
            ok;
        {error, _} = Error ->
            Error
    end;
validate_tags(_) ->
    {error, invalid_type}.

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([AccessKeyID, SecretAccessKey, EC2Host, Groups, Tags]) ->
    Config = erlcloud_ec2:new(AccessKeyID, SecretAccessKey, EC2Host),
    Connect = nodefinder_app:connect_type(),
    case preprocess(Tags, tag) of
        {ok, TagsExpressionTree} ->
            case preprocess(Groups, group) of
                {ok, GroupsExpressionTree}
                    when TagsExpressionTree == ?NULL_EXPRESSION,
                         GroupsExpressionTree == ?NULL_EXPRESSION ->
                    {stop, {error, null_selection}};
                {ok, GroupsExpressionTree} ->
                    TagsMerged = tags_merge(TagsExpressionTree),
                    TagsFilter = tags_filter(TagsMerged),
                    case do_discover(#state{ec2_config = Config,
                                            groups = GroupsExpressionTree,
                                            tags = TagsExpressionTree,
                                            tags_filter = TagsFilter,
                                            nodes = [],
                                            connect = Connect}) of
                        {ok, #state{}} = Success ->
                            Success;
                        {error, _} = Error ->
                            {stop, Error}
                    end;
                {error, _} = Error ->
                    {stop, Error}
            end;
        {error, _} = Error ->
            {stop, Error}
    end.

handle_call(discover, _From, State) ->
    case do_discover(State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, _} = Error ->
            {stop, Error, {error, discover_failed}, State}
    end;
handle_call(Request, _From, State) ->
    {stop, lists:flatten(io_lib:format("Unknown call \"~p\"", [Request])),
     error, State}.

handle_cast(Request, State) ->
    {stop, lists:flatten(io_lib:format("Unknown cast \"~p\"", [Request])),
     State}.

handle_info(Request, State) ->
    {stop, lists:flatten(io_lib:format("Unknown info \"~p\"", [Request])),
     State}.

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State, _Extra) -> 
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

preprocess_set_cleanup([], [], L2, _) ->
    lists:reverse(L2);
preprocess_set_cleanup([], Merged, L2, Condition) ->
    [{Condition, Merged} | lists:reverse(L2)];
preprocess_set_cleanup([{Condition, L1} | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged ++ L1, L2, Condition);
preprocess_set_cleanup([{'AND', []} | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged, L2, Condition);
preprocess_set_cleanup([{'AND', _} = Entry | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged, [Entry | L2], Condition);
preprocess_set_cleanup([{'OR', []} | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged, L2, Condition);
preprocess_set_cleanup([{'OR', _} = Entry | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged, [Entry | L2], Condition);
preprocess_set_cleanup([Entry | L0], Merged, L2, Condition) ->
    preprocess_set_cleanup(L0, Merged, [Entry | L2], Condition).

preprocess_set_cleanup(L, Condition) ->
    preprocess_set_cleanup(L, [], [], Condition).

preprocess_set_element_tags_value([]) ->
    ok;
preprocess_set_element_tags_value([[I | _] | Values])
    when is_integer(I) ->
    preprocess_set_element_tags_value(Values);
preprocess_set_element_tags_value([Invalid | _]) ->
    {error, {tag_value, Invalid}}.

preprocess_set_element_tags_key([], _, Lookup) ->
    {ok, Lookup};
preprocess_set_element_tags_key([[I | _] = Key | Keys], Values, Lookup)
    when is_integer(I) ->
    preprocess_set_element_tags_key(Keys, Values,
                                    orddict:store(Key, Values, Lookup));
preprocess_set_element_tags_key([Invalid | _], _, _) ->
    {error, {tag_key, Invalid}}.
    
preprocess_set_element_tags(Keys, Values)
    when is_list(Keys), is_list(Values) ->
    case preprocess_set_element_tags_value(Values) of
        ok ->
            preprocess_set_element_tags_key(lists:usort(Keys),
                                            lists:usort(Values),
                                            orddict:new());
        {error, _} = Error ->
            Error
    end.

preprocess_set_element([I | _] = Group, group)
    when is_integer(I) ->
    {ok, Group};
preprocess_set_element([I | _] = Key, tag)
    when is_integer(I) ->
    preprocess_set_element_tags([Key], []);
preprocess_set_element([[I | _] | _] = Keys, tag)
    when is_integer(I) ->
    preprocess_set_element_tags(Keys, []);
preprocess_set_element({[I0 | _] = Key, [I1 | _] = Value}, tag)
    when is_integer(I0), is_integer(I1) ->
    preprocess_set_element_tags([Key], [Value]);
preprocess_set_element({[[I0 | _] | _] = Keys, [I1 | _] = Value}, tag)
    when is_integer(I0), is_integer(I1) ->
    preprocess_set_element_tags(Keys, [Value]);
preprocess_set_element({[I0 | _] = Key, [[I1 | _] | _] = Values}, tag)
    when is_integer(I0), is_integer(I1) ->
    preprocess_set_element_tags([Key], Values);
preprocess_set_element({[[I0 | _] | _] = Keys, [[I1 | _] | _] = Values}, tag)
    when is_integer(I0), is_integer(I1) ->
    preprocess_set_element_tags(Keys, Values);
preprocess_set_element(Entry, Type) ->
    {error, {Type, Entry}}.

preprocess_set([], L2, _Type) ->
    {ok, lists:reverse(L2)};
preprocess_set([{'AND', L1} | L0], L2, Type) ->
    case preprocess_set(preprocess_set_cleanup(L1, 'AND'), Type) of
        {ok, [{'AND', NewL1H} | NewL1T]} ->
            % merge ANDs at the same level
            preprocess_set(L0, [{'AND', NewL1H ++ NewL1T} | L2], Type);
        {ok, NewL1} ->
            preprocess_set(L0, [{'AND', NewL1} | L2], Type);
        {error, _} = Error ->
            Error
    end;
preprocess_set([{'OR', L1} | L0], L2, Type) ->
    case preprocess_set(preprocess_set_cleanup(L1, 'OR'), Type) of
        {ok, [{'OR', NewL1H} | NewL1T]} ->
            % merge ORs at the same level
            preprocess_set(L0, [{'OR', NewL1H ++ NewL1T} | L2], Type);
        {ok, NewL1} ->
            preprocess_set(L0, [{'OR', NewL1} | L2], Type);
        {error, _} = Error ->
            Error
    end;
preprocess_set([Entry | L0], L2, Type) ->
    case preprocess_set_element(Entry, Type) of
        {ok, NewEntry} ->
            preprocess_set(L0, [NewEntry | L2], Type);
        {error, _} = Error ->
            Error
    end.
preprocess_set(L, Type) ->
    preprocess_set(L, [], Type).

preprocess([{'OR', ORs}] = L, Type)
    when is_list(ORs) ->
    preprocess_set(L, Type);
preprocess(L, Type) ->
    preprocess_set([{'OR', L}], Type).

tags_merge_f(_, [], _) ->
    [];
tags_merge_f(_, _, []) ->
    [];
tags_merge_f(_, Value1, Value2) ->
    lists:umerge(Value1, Value2).

tags_merge([], Lookup) ->
    Lookup;
tags_merge([{'AND', L1} | L0], Lookup) ->
    tags_merge(L0, tags_merge(L1, Lookup));
tags_merge([{'OR', L1} | L0], Lookup) ->
    tags_merge(L0, tags_merge(L1, Lookup));
tags_merge([Tags | L0], Lookup) ->
    tags_merge(L0, orddict:merge(fun tags_merge_f/3, Tags, Lookup)).

tags_merge(L) ->
    tags_merge(L, orddict:new()).

tags_filter(Merged) ->
    {Keys, Values} = lists:foldl(fun({K0, V0}, {K1, V1}) ->
        {lists:umerge(K1, [K0]), lists:umerge(V1, V0)}
    end, {[], []}, Merged),
    if
        Values == [] ->
            [{key, Keys}];
        true ->
            [{key, Keys}, {value, Values}]
    end.

process_filter(Group, EC2Instances, group) ->
    lists:filter(fun(Reservation) ->
        {_, GroupSet} = lists:keyfind(group_set, 1, Reservation),
        lists:member(Group, GroupSet)
    end, EC2Instances);
process_filter(Tags, EC2Tags, tag) ->
    lists:filter(fun(#ec2_tag{key = Key, value = Value}) ->
        case orddict:find(Key, Tags) of
            {ok, []} ->
                true;
            {ok, Values} ->
                lists:member(Value, Values);
            error ->
                false
        end
    end, EC2Tags).

process_and([], EC2Data, _Type) ->
    EC2Data;
process_and([{'AND', L1} | L0], EC2Data, Type) ->
    process_and(L0, process_and(L1, EC2Data, Type), Type);
process_and([{'OR', L1} | L0], EC2Data, Type) ->
    process_and(L0, process_or(L1, EC2Data, Type), Type);
process_and([Data | L0], EC2Data, Type) ->
    process_and(L0, process_filter(Data, EC2Data, Type), Type).

process_or([], EC2DataOut, _EC2DataIn, _Type) ->
    EC2DataOut;
process_or([{'AND', L1} | L0], EC2DataOut, EC2DataIn, Type) ->
    NewEC2DataOut = lists:umerge(process_and(L1, EC2DataIn, Type),
                                 EC2DataOut),
    process_or(L0, NewEC2DataOut, EC2DataIn, Type);
process_or([{'OR', L1} | L0], EC2DataOut, EC2DataIn, Type) ->
    NewEC2DataOut = lists:umerge(process_or(L1, EC2DataIn, Type),
                                 EC2DataOut),
    process_or(L0, NewEC2DataOut, EC2DataIn, Type);
process_or([Data | L0], EC2DataOut, EC2DataIn, Type) ->
    NewEC2DataOut = lists:umerge(process_filter(Data, EC2DataIn, Type),
                                 EC2DataOut),
    process_or(L0, NewEC2DataOut, EC2DataIn, Type).

process_or(L, EC2Data, Type) ->
    process_or(L, [], EC2Data, Type).

process([{'OR', L}], EC2Instances, group) ->
    % output list of private dns names
    lists:foldl(fun(Reservation, Hosts) ->
        {_, InstancesSet} = lists:keyfind(instances_set, 1, Reservation),
        update_from_instances_set(InstancesSet, Hosts)
    end, [], process_or(L, lists:usort(EC2Instances), group));
process([{'OR', L}], EC2Tags, tag) ->
    % output list of instance ids
    [Id ||
     #ec2_tag{resource_id = Id} <- process_or(L, lists:usort(EC2Tags), tag)].

node_names(Hosts, #state{} = State) ->
    Name = string:sub_word(erlang:atom_to_list(node()), 1, $@),
    Nodes = lists:foldl(fun(Host, L) ->
        lists:umerge(L, [erlang:list_to_atom(Name ++ [$@ | Host])])
    end, [], Hosts),
    {ok, Nodes, State}.

ec2_instances_get(#state{ec2_config = Config,
                         ec2_instances = OldResult} = State) ->
    case erlcloud_ec2:describe_instances(Config) of
        {ok, OldResult} ->
            {ok, false, State};
        {ok, NewResult} ->
            {ok, true, State#state{ec2_instances = NewResult}};
        {error, _} = Error ->
            Error
    end.

ec2_tagged_instances_get_entries(Tags, Filter, Config) ->
    case erlcloud_ec2:describe_tags([{resource_type, ["instance"]} |
                                     Filter], Config) of
        {ok, EC2Tags} ->
            {ok, process(Tags, EC2Tags, tag)};
        {error, _} = Error ->
            Error
    end.

ec2_tagged_instances_get(#state{tags = ?NULL_EXPRESSION} = State) ->
    {ok, false, State};
ec2_tagged_instances_get(#state{ec2_config = Config,
                                ec2_tagged_instances = OldResult,
                                tags = Tags,
                                tags_filter = Filter} = State) ->
    case ec2_tagged_instances_get_entries(Tags, Filter, Config) of
        {ok, OldResult} ->
            {ok, false, State};
        {ok, NewResult} ->
            {ok, true, State#state{ec2_tagged_instances = NewResult}};
        {error, _} = Error ->
            Error
    end.

update_from_instance(Instance, Hosts) ->
    {_, Host} = lists:keyfind(private_dns_name, 1, Instance),
    lists:umerge(Hosts, [Host]).

update_from_instances_set([], Hosts) ->
    Hosts;
update_from_instances_set([Instance | InstancesSet], Hosts) ->
    update_from_instances_set(InstancesSet,
                              update_from_instance(Instance, Hosts)).

update_from_instances_set([], Hosts, _) ->
    Hosts;
update_from_instances_set([Instance | InstancesSet], Hosts, F) ->
    NextHosts = case F(Instance) of
        true ->
            update_from_instance(Instance, Hosts);
        false ->
            Hosts
    end,
    update_from_instances_set(InstancesSet, NextHosts, F).

update_from_groups(#state{ec2_instances = EC2Instances,
                          groups = Groups} = State) ->
    HostsFound = process(Groups, EC2Instances, group),
    node_names(HostsFound, State).

update_from_tags(#state{ec2_instances = Instances,
                        ec2_tagged_instances = TaggedInstances} = State) ->
    HostsFound = lists:foldl(fun(InstanceId, Hosts) ->
        Check = fun(Instance) ->
            case lists:keyfind(instance_id, 1, Instance) of
                {_, InstanceId} ->
                    true;
                {_, _} ->
                    false
            end
        end,
        lists:foldl(fun(Reservation, NextHosts) ->
            {_, InstancesSet} = lists:keyfind(instances_set, 1, Reservation),
            update_from_instances_set(InstancesSet, NextHosts, Check)
        end, Hosts, Instances)
    end, [], TaggedInstances),
    node_names(HostsFound, State).

updates_gather(true, true, State) ->
    case update_from_groups(State) of
        {ok, Nodes0, NextState} ->
            case update_from_tags(NextState) of
                {ok, Nodes1, NewState} ->
                    {ok, lists:umerge(Nodes0, Nodes1), NewState}
            end
    end;
updates_gather(true, false,
               #state{nodes = OldNodes} = State) ->
    case update_from_groups(State) of
        {ok, Nodes, NewState} ->
            {ok, lists:umerge(Nodes, OldNodes), NewState}
    end;
updates_gather(false, true,
               #state{nodes = OldNodes} = State) ->
    case update_from_tags(State) of
        {ok, Nodes, NewState} ->
            {ok, lists:umerge(Nodes, OldNodes), NewState}
    end;
updates_gather(false, false,
               #state{nodes = OldNodes} = State) ->
    {ok, OldNodes, State}.

update_nodes(Nodes,
             #state{connect = Connect} = State) ->
    ConnectNodes = lists:subtract(Nodes, nodes()),
    pforeach(fun(Node) ->
        % avoid the possibly long synchronous call here
        connect_node(Connect, Node)
    end, ConnectNodes),
    State#state{nodes = Nodes}.

update(UpdateGroups, UpdateTags, State) ->
    case updates_gather(UpdateGroups, UpdateTags, State) of
        {ok, Nodes, NewState} ->
            {ok, update_nodes(Nodes, NewState)}
    end.

do_discover(#state{} = State) ->
    case ec2_instances_get(State) of
        {ok, UpdatedGroups, NextState} ->
            case ec2_tagged_instances_get(NextState) of
                {ok, UpdatedTags, NewState} ->
                    update(UpdatedGroups, UpdatedTags, NewState);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

connect_node(visible, Node) ->
    net_kernel:connect_node(Node);
connect_node(hidden, Node) ->
    net_kernel:hidden_connect_node(Node).

pforeach(_, []) ->
    ok;
pforeach(F, L) ->
    [erlang:spawn_link(fun() -> F(E) end) || E <- L],
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

logic_case1_tags() ->
    [#ec2_tag{resource_id = "A1",
              key = "A",
              value = "A"},
     #ec2_tag{resource_id = "A2",
              key = "A",
              value = "B"},
     #ec2_tag{resource_id = "B1",
              key = "B",
              value = "A"},
     #ec2_tag{resource_id = "C1",
              key = "C",
              value = "A"},
     #ec2_tag{resource_id = "C2",
              key = "C",
              value = "B"},
     #ec2_tag{resource_id = "C3",
              key = "C",
              value = "C"},
     #ec2_tag{resource_id = "C4",
              key = "C",
              value = "C"},
     #ec2_tag{resource_id = "C5",
              key = "C",
              value = "C"}].

logic_case1_tags_preprocess(TagsInput) ->
    true = is_list(TagsInput),
    {ok, TagsOutput} = preprocess(TagsInput, tag),
    TagsOutput.

logic_case1_tags_process(TagsInput) ->
    process(logic_case1_tags_preprocess(TagsInput),
            logic_case1_tags(), tag).

logic_case2_groups() ->
    [[{group_set,
       ["A", "A/A"]},
      {instances_set,
       [[{private_dns_name, "A1"}]]}],
     [{group_set,
       ["A", "A/B"]},
      {instances_set,
       [[{private_dns_name, "A2"}]]}],
     [{group_set,
       ["B", "B/A"]},
      {instances_set,
       [[{private_dns_name, "B1"}]]}],
     [{group_set,
       ["C", "C/A"]},
      {instances_set,
       [[{private_dns_name, "C1"}]]}],
     [{group_set,
       ["C", "C/B"]},
      {instances_set,
       [[{private_dns_name, "C2"}]]}],
     [{group_set,
       ["C", "C/C"]},
      {instances_set,
       [[{private_dns_name, "C3"}]]}],
     [{group_set,
       ["C", "C/C"]},
      {instances_set,
       [[{private_dns_name, "C4"}]]}],
     [{group_set,
       ["C", "C/C"]},
      {instances_set,
       [[{private_dns_name, "C5"}]]}]].

logic_case2_groups_preprocess(GroupsInput) ->
    true = is_list(GroupsInput),
    {ok, GroupsOutput} = preprocess(GroupsInput, group),
    GroupsOutput.

logic_case2_groups_process(GroupsInput) ->
    process(logic_case2_groups_preprocess(GroupsInput),
            logic_case2_groups(), group).

logic1_case1_test() ->
    TagsInput1 = ["C"],
    TagsInput2 = [["C"]],
    TagsInput3 = [{'OR', ["C"]}],
    TagsInput4 = [{'OR', [["C"]]}],
    [{'OR',[[{"C",[]}]]}] = logic_case1_tags_preprocess(TagsInput1),
    [{'OR',[[{"C",[]}]]}] = logic_case1_tags_preprocess(TagsInput2),
    [{'OR',[[{"C",[]}]]}] = logic_case1_tags_preprocess(TagsInput3),
    [{'OR',[[{"C",[]}]]}] = logic_case1_tags_preprocess(TagsInput4),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case1_tags_process(TagsInput1),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case1_tags_process(TagsInput2),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case1_tags_process(TagsInput3),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case1_tags_process(TagsInput4),
    ok.

logic2_case1_test() ->
    TagsInput1 = [{'AND', [{"C", "B"}, "C"]}],
    TagsInput2 = [{'AND', ["C", {"C", "B"}]}],
    TagsInput3 = [{'AND', ["B", {"C", "B"}]}],
    [{'OR',[{'AND',[[{"C",["B"]}],[{"C",[]}]]}]}
     ] = logic_case1_tags_preprocess(TagsInput1),
    [{'OR',[{'AND',[[{"C",[]}],[{"C",["B"]}]]}]}
     ] = logic_case1_tags_preprocess(TagsInput2),
    [{'OR',[{'AND',[[{"B",[]}],[{"C",["B"]}]]}]}
     ] = logic_case1_tags_preprocess(TagsInput3),
    ["C2"] = logic_case1_tags_process(TagsInput1),
    ["C2"] = logic_case1_tags_process(TagsInput2),
    [] = logic_case1_tags_process(TagsInput3),
    ok.

logic3_case1_test() ->
    TagsInput1 = [{'OR', [{'AND', [{"C", "B"}, "C"]},
                          {'AND', ["A", {"A", "B"}]}]}],
    [{'OR',[{'AND',[[{"C",["B"]}],[{"C",[]}]]},
            {'AND',[[{"A",[]}],[{"A",["B"]}]]}]}
     ] = logic_case1_tags_preprocess(TagsInput1),
    ["A2", "C2"] = logic_case1_tags_process(TagsInput1),
    ok.

logic4_case1_test() ->
    TagsInput1 = [{'AND', [{"C", ["C"]}, "C"]},
                  {'AND', [{'OR', ["C", "C", "C", "C"]}, {"C", ["B"]}]},
                  {'AND', ["A", {["A", "B", "C"], ["A", "B"]}, {"A", "B"}]}],
    [{'OR',[{'AND',[[{"C",["C"]}],[{"C",[]}]]},
            {'AND',[{'OR',[[{"C",[]}],[{"C",[]}],[{"C",[]}],[{"C",[]}]]},
                    [{"C",["B"]}]]},
            {'AND',[[{"A",[]}],
                    [{"A",["A","B"]},
                     {"B",["A","B"]},
                     {"C",["A","B"]}],
                    [{"A",["B"]}]]}]}
     ] = logic_case1_tags_preprocess(TagsInput1),
    ["A2", "C2", "C3", "C4", "C5"] = logic_case1_tags_process(TagsInput1),
    ok.

logic5_case1_test() ->
    TagsInput1 = [{'OR', [{"C", ["C"]}, "C"]},
                  {'OR', [{'OR', ["C", "C", "C", "C"]}, {"C", ["B"]}]},
                  {'OR', ["A", {["A", "B", "C"], ["A", "B"]}, {"A", "B"}]}],
    [{'OR',[[{"C",[]}],
            [{"C",[]}],
            [{"C",[]}],
            [{"C",[]}],
            [{"C",["C"]}],
            [{"C",[]}],
            [{"C",["B"]}],
            [{"A",[]}],
            [{"A",["A","B"]},{"B",["A","B"]},{"C",["A","B"]}],
            [{"A",["B"]}]]}
     ] = logic_case1_tags_preprocess(TagsInput1),
    ["A1","A2","B1","C1","C2","C3","C4","C5"
     ] = logic_case1_tags_process(TagsInput1),
    ok.

logic1_case2_test() ->
    GroupsInput1 = ["C"],
    GroupsInput2 = [{'OR', ["C"]}],
    [{'OR',["C"]}] = logic_case2_groups_preprocess(GroupsInput1),
    [{'OR',["C"]}] = logic_case2_groups_preprocess(GroupsInput2),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case2_groups_process(GroupsInput1),
    ["C1", "C2", "C3", "C4", "C5"] = logic_case2_groups_process(GroupsInput2),
    ok.

logic2_case2_test() ->
    GroupsInput1 = [{'AND', ["C/B", "C"]}],
    GroupsInput2 = [{'AND', ["C", "C/B"]}],
    GroupsInput3 = [{'AND', ["B", "C/B"]}],
    [{'OR',[{'AND',["C/B","C"]}]}
     ] = logic_case2_groups_preprocess(GroupsInput1),
    [{'OR',[{'AND',["C","C/B"]}]}
     ] = logic_case2_groups_preprocess(GroupsInput2),
    [{'OR',[{'AND',["B","C/B"]}]}
     ] = logic_case2_groups_preprocess(GroupsInput3),
    ["C2"] = logic_case2_groups_process(GroupsInput1),
    ["C2"] = logic_case2_groups_process(GroupsInput2),
    [] = logic_case2_groups_process(GroupsInput3),
    ok.

logic3_case2_test() ->
    GroupsInput1 = [{'OR', [{'AND', ["C/B", "C"]},
                            {'AND', ["A", "A/B"]}]}],
    [{'OR',[{'AND',["C/B","C"]},
            {'AND',["A","A/B"]}]}
     ] = logic_case2_groups_preprocess(GroupsInput1),
    ["A2", "C2"] = logic_case2_groups_process(GroupsInput1),
    ok.

logic4_case2_test() ->
    GroupsInput1 = [{'AND', ["C/C", "C"]},
                    {'AND', [{'OR', ["C", "C", "C", "C"]}, "C/B"]},
                    {'AND', ["A",
                             {'OR', ["A/A", "A/B",
                                     "B/A", "B/B",
                                     "C/A", "C/B"]},
                             "A/B"]}],
    [{'OR',[{'AND',["C/C","C"]},
            {'AND',[{'OR',["C","C","C","C"]},
                    "C/B"]},
            {'AND',["A",
                    {'OR', ["A/A", "A/B",
                            "B/A", "B/B",
                            "C/A", "C/B"]},
                    "A/B"]}]}
     ] = logic_case2_groups_preprocess(GroupsInput1),
    ["A2", "C2", "C3", "C4", "C5"] = logic_case2_groups_process(GroupsInput1),
    ok.

-endif.
