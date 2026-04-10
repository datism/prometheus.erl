%% @doc Exports all collected metrics as a flat list of Erlang terms.
%%
%% Each metric sample is represented as a 4-tuple:
%% `{MetricName, Type, Labels, Value}'
%%
%% Where:
%% <ul>
%%   <li>`MetricName' is a binary (histograms/summaries get `_bucket', `_sum',
%%       `_count' suffixes)</li>
%%   <li>`Type' is a lowercase atom: `counter', `gauge', `histogram',
%%       `summary', or `untyped'</li>
%%   <li>`Labels' is a proplist `[{BinaryName, BinaryValue}]'</li>
%%   <li>`Value' is an integer or float</li>
%% </ul>
%%
%% Example:
%% ```
%% prometheus_array_format:format().
%% [{<<"http_requests_total">>, counter, [{<<"method">>, <<"GET">>}], 42},
%%  {<<"latency_bucket">>,      histogram, [{<<"le">>, <<"1.0">>}],   5},
%%  {<<"latency_sum">>,         histogram, [],                         2.3},
%%  {<<"latency_count">>,       histogram, [],                         10}]
%% '''
-module(prometheus_array_format).

-include("prometheus_model.hrl").

-export([format/0, format/1]).

%% @doc Exports metrics from the default registry.
-spec format() -> [{binary(), atom(), [{binary(), binary()}], number()}].
format() ->
    format(default).

%% @doc Exports metrics from the given registry.
-spec format(Registry :: atom()) -> [{binary(), atom(), [{binary(), binary()}], number()}].
format(Registry) ->
    MFs = collect_mfs(Registry),
    lists:flatmap(fun mf_to_tuples/1, MFs).

%%====================================================================
%% Internal functions
%%====================================================================

collect_mfs(Registry) ->
    put(?MODULE, []),
    Callback = fun(Reg, Collector) ->
        MFCallback = fun(MF) -> put(?MODULE, [MF | get(?MODULE)]) end,
        prometheus_collector:collect_mf(Reg, Collector, MFCallback)
    end,
    prometheus_registry:collect(Registry, Callback),
    Result = lists:reverse(get(?MODULE)),
    erase(?MODULE),
    Result.

mf_to_tuples(#'MetricFamily'{name = Name, type = Type, metric = Metrics}) ->
    T = atom_type(Type),
    NameBin = iolist_to_binary(Name),
    lists:flatmap(fun(M) -> metric_to_tuples(NameBin, T, M) end, Metrics).

atom_type('COUNTER')   -> counter;
atom_type('GAUGE')     -> gauge;
atom_type('HISTOGRAM') -> histogram;
atom_type('SUMMARY')   -> summary;
atom_type(_)           -> untyped.

metric_to_tuples(Name, T, #'Metric'{label = Labels, counter = #'Counter'{value = V}}) ->
    [{Name, T, extract_labels(Labels), V}];
metric_to_tuples(Name, T, #'Metric'{label = Labels, gauge = #'Gauge'{value = V}}) ->
    [{Name, T, extract_labels(Labels), V}];
metric_to_tuples(Name, T, #'Metric'{label = Labels, untyped = #'Untyped'{value = V}}) ->
    [{Name, T, extract_labels(Labels), V}];
metric_to_tuples(Name, T, #'Metric'{label = Labels,
        summary = #'Summary'{sample_count = C, sample_sum = S, quantile = Qs}}) ->
    Base = extract_labels(Labels),
    QTerms = [{Name, T, Base ++ [{<<"quantile">>, format_float(Q)}], V}
              || #'Quantile'{quantile = Q, value = V} <- Qs],
    QTerms ++ [
        {<<Name/binary, "_sum">>,   T, Base, S},
        {<<Name/binary, "_count">>, T, Base, C}
    ];
metric_to_tuples(Name, T, #'Metric'{label = Labels,
        histogram = #'Histogram'{sample_count = C, sample_sum = S, bucket = Bs}}) ->
    Base = extract_labels(Labels),
    BTerms = [{<<Name/binary, "_bucket">>, T,
               Base ++ [{<<"le">>, format_bound(UB)}], CC}
              || #'Bucket'{upper_bound = UB, cumulative_count = CC} <- Bs],
    BTerms ++ [
        {<<Name/binary, "_sum">>,   T, Base, S},
        {<<Name/binary, "_count">>, T, Base, C}
    ].

extract_labels(Labels) when is_list(Labels) ->
    [{iolist_to_binary(N), iolist_to_binary(V)}
     || #'LabelPair'{name = N, value = V} <- Labels];
extract_labels(_) ->
    [].

format_bound(infinity) ->
    <<"+Inf">>;
format_bound(N) when is_integer(N) ->
    integer_to_binary(N);
format_bound(N) ->
    float_to_binary(N, [{decimals, 10}, compact]).

format_float(N) when is_integer(N) ->
    integer_to_binary(N);
format_float(N) ->
    float_to_binary(N, [{decimals, 10}, compact]).
