CREATE OR REPLACE FUNCTION jobcenter.do_check_same_workflow(a_task1_id integer, a_task2_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO jobcenter, pg_catalog, pg_temp
AS $function$BEGIN
 	--RAISE NOTICE 'a_task1_id % a_task2_id %', a_task1_id, a_task2_id;
	IF a_task1_id IS NULL or a_task2_id IS NULL THEN
		RETURN TRUE;
	END IF;

	PERFORM true FROM
		tasks AS t1
		JOIN tasks AS t2
		USING (workflow_id)
	WHERE
		t1.task_id = a_task1_id
		AND t2.task_id = a_task2_id;

	RETURN FOUND;
END;$function$
