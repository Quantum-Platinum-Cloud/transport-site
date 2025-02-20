defmodule DB.DatasetDBTest do
  @moduledoc """
  Tests on the Dataset schema
  """
  use DB.DatabaseCase, cleanup: [:datasets]
  use Oban.Testing, repo: DB.Repo
  alias DB.Repo
  import DB.Factory
  import ExUnit.CaptureLog
  import Ecto.Query

  test "delete_parent_dataset" do
    parent_dataset = Repo.insert!(%Dataset{})
    linked_aom = Repo.insert!(%AOM{parent_dataset_id: parent_dataset.id, nom: "Jolie AOM"})

    # linked_aom is supposed to have a parent_dataset id
    assert not is_nil(linked_aom.parent_dataset_id)

    # it should be possible to delete a dataset even if it is an AOM's parent dataset
    Repo.delete!(parent_dataset)

    # after parent deletion, the aom should have a nil parent_dataset
    linked_aom = Repo.get!(AOM, linked_aom.id)
    assert is_nil(linked_aom.parent_dataset_id)
  end

  test "delete dataset associated to a commune" do
    commune = insert(:commune)

    dataset =
      :dataset
      |> insert()
      |> Repo.preload(:communes)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:communes, [commune])
      |> Repo.update!()

    # check the assoc succeeded
    [associated_commune] = dataset.communes
    assert associated_commune.id == commune.id

    # the deletion will raise if no on_delete action is defined because of the presence of a foreign key
    Repo.delete!(dataset)
  end

  describe "changeset of a dataset" do
    test "empty params are rejected" do
      assert {:error, _} = Dataset.changeset(%{})
    end

    test "slug is required" do
      {{:error, _}, logs} = with_log(fn -> Dataset.changeset(%{"datagouv_id" => "1"}) end)
      assert logs =~ "error while importing dataset"
    end

    test "some geographic link is required" do
      {{:error, _}, logs} = with_log(fn -> Dataset.changeset(%{"datagouv_id" => "1", "slug" => "ma_limace"}) end)
      assert logs =~ "error while importing dataset"
    end

    test "with insee code of a commune linked to an aom, it works" do
      assert {:ok, _} = Dataset.changeset(%{"datagouv_id" => "1", "slug" => "ma_limace", "insee" => "38185"})
    end

    test "with datagouv_zone only, it fails" do
      {{:error, _}, logs} =
        with_log(fn ->
          Dataset.changeset(%{
            "datagouv_id" => "1",
            "slug" => "ma_limace",
            "zones" => ["38185"]
          })
        end)

      assert logs =~ "error while importing dataset"
    end

    test "with datagouv_zone and territory name, it works" do
      assert {:ok, _} =
               Dataset.changeset(%{
                 "datagouv_id" => "1",
                 "slug" => "ma_limace",
                 "zones" => ["38185"],
                 "associated_territory_name" => "paris"
               })
    end

    test "national dataset" do
      assert {:ok, _} =
               Dataset.changeset(%{
                 "datagouv_id" => "1",
                 "slug" => "ma_limace",
                 "national_dataset" => "true"
               })
    end

    test "territory mutual exclusion" do
      {{:error, _}, logs} =
        with_log(fn ->
          Dataset.changeset(%{
            "datagouv_id" => "1",
            "slug" => "ma_limace",
            "national_dataset" => "true",
            "insee" => "38185"
          })
        end)

      assert logs =~ "error while importing dataset"
    end

    test "territory mutual exclusion with nil INSEE code resets AOM" do
      %{datagouv_id: datagouv_id} = insert(:dataset)

      assert {:ok, %Ecto.Changeset{changes: %{aom_id: nil, region_id: 1}}} =
               Dataset.changeset(%{
                 "datagouv_id" => datagouv_id,
                 "national_dataset" => "true",
                 "insee" => nil
               })
    end

    test "has_real_time=true" do
      changeset =
        Dataset.changeset(%{
          "datagouv_id" => "1",
          "slug" => "ma_limace",
          "insee" => "38185",
          "resources" => [
            %{"format" => "gbfs", "url" => "coucou", "datagouv_id" => "pouet"},
            %{"format" => "gtfs", "url" => "coucou", "datagouv_id" => "pouet"}
          ]
        })

      assert {:ok, %Ecto.Changeset{changes: %{has_realtime: true}}} = changeset
    end

    test "has_real_time=false" do
      changeset =
        Dataset.changeset(%{
          "datagouv_id" => "1",
          "slug" => "ma_limace",
          "insee" => "38185",
          "resources" => [%{"format" => "gtfs", "url" => "coucou", "datagouv_id" => "pouet"}]
        })

      assert {:ok, %Ecto.Changeset{changes: %{has_realtime: false}}} = changeset
    end

    test "when licence changes from lov2 to fr-lo (both licence ouverte)" do
      %{datagouv_id: datagouv_id} = insert(:dataset, licence: "lov2", datagouv_id: Ecto.UUID.generate())
      assert {:ok, _} = Dataset.changeset(%{"datagouv_id" => datagouv_id, "licence" => "fr-lo"})
      assert [] == all_enqueued()
    end

    test "when licence changes from odbl to licence ouverte" do
      %{datagouv_id: datagouv_id, id: dataset_id} =
        insert(:dataset, licence: "odc-odbl", datagouv_id: Ecto.UUID.generate())

      assert {:ok, _} = Dataset.changeset(%{"datagouv_id" => datagouv_id, "licence" => "fr-lo"})

      assert [%Oban.Job{worker: "Transport.Jobs.DatasetNowLicenceOuverteJob", args: %{"dataset_id" => ^dataset_id}}] =
               all_enqueued()
    end

    test "when dataset does not exist yet and the licence is licence ouverte" do
      assert {:ok, _} =
               Dataset.changeset(%{
                 "datagouv_id" => Ecto.UUID.generate(),
                 "licence" => "fr-lo",
                 "national_dataset" => "true",
                 "slug" => "ma_limace"
               })

      assert [] == all_enqueued()
    end
  end

  describe "resources last content update time" do
    test "for a dataset, get resources last update times" do
      %{id: dataset_id} = insert(:dataset, %{datagouv_id: "xxx", datagouv_title: "coucou"})

      %{id: resource_id_1} = insert(:resource, dataset_id: dataset_id)
      %{id: resource_id_2} = insert(:resource, dataset_id: dataset_id)

      # resource 1
      insert(:resource_history, %{
        resource_id: resource_id_1,
        payload: %{download_datetime: DateTime.utc_now() |> DateTime.add(-7200)}
      })

      insert(:resource_history, %{
        resource_id: resource_id_1,
        payload: %{download_datetime: resource_1_last_update_time = DateTime.utc_now() |> DateTime.add(-3600)}
      })

      # resource 2
      insert(:resource_history, %{resource_id: resource_id_2, payload: %{}})

      dataset = DB.Dataset |> preload(:resources) |> DB.Repo.get!(dataset_id)

      assert %{resource_id_1 => resource_1_last_update_time, resource_id_2 => nil} ==
               Dataset.resources_content_updated_at(dataset)
    end

    defp insert_dataset_resource do
      dataset = insert(:dataset)
      %{id: resource_id} = insert(:resource, dataset: dataset)

      {dataset, resource_id}
    end

    test "1 resource, basic case" do
      {dataset, resource_id} = insert_dataset_resource()

      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{download_datetime: DateTime.utc_now() |> DateTime.add(-7200)}
      })

      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{download_datetime: expected_last_update_time = DateTime.utc_now() |> DateTime.add(-3600)}
      })

      assert %{resource_id => expected_last_update_time} == Dataset.resources_content_updated_at(dataset)
    end

    test "only one resource history, we don't know the resource last content update time" do
      {dataset, resource_id} = insert_dataset_resource()

      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{download_datetime: DateTime.utc_now() |> DateTime.add(-7200)}
      })

      assert Dataset.resources_content_updated_at(dataset) == %{resource_id => nil}
    end

    test "last content update time, download_datetime not in payload" do
      {dataset, resource_id} = insert_dataset_resource()

      insert(:resource_history, %{resource_id: resource_id, payload: %{}})

      assert Dataset.resources_content_updated_at(dataset) == %{resource_id => nil}
    end

    test "last content update time, some download_datetime not in payload" do
      {dataset, resource_id} = insert_dataset_resource()

      insert(:resource_history, %{resource_id: resource_id, payload: %{}})

      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{download_datetime: DateTime.utc_now() |> DateTime.add(-7200)}
      })

      insert(:resource_history, %{
        resource_id: resource_id,
        payload: %{download_datetime: expected_last_update_time = DateTime.utc_now() |> DateTime.add(-3600)}
      })

      assert Dataset.resources_content_updated_at(dataset) == %{resource_id => expected_last_update_time}
    end
  end

  test "get_other_datasets" do
    aom = insert(:aom)
    dataset = insert(:dataset, aom: aom, is_active: true)

    assert Dataset.get_other_datasets(dataset) == []

    _inactive_dataset = insert(:dataset, aom: aom, is_active: false)

    assert Dataset.get_other_datasets(dataset) == []

    other_dataset = insert(:dataset, aom: aom, is_active: true)

    assert dataset |> Dataset.get_other_datasets() |> Enum.map(& &1.id) == [other_dataset.id]
  end

  test "formats" do
    dataset = insert(:dataset)
    insert(:resource, format: "GTFS", dataset: dataset)
    insert(:resource, format: "zip", dataset: dataset, is_community_resource: true)
    insert(:resource, format: "csv", dataset: dataset)

    assert ["GTFS", "csv"] == dataset |> DB.Repo.preload(:resources) |> Dataset.formats()
  end

  test "validate" do
    dataset = insert(:dataset)
    %{id: gtfs_resource_id} = insert(:resource, format: "GTFS", dataset: dataset)
    %{id: gbfs_resource_id} = insert(:resource, format: "gbfs", dataset: dataset)
    # Ignored because it's a community resource
    insert(:resource, format: "GTFS", dataset: dataset, is_community_resource: true)

    Dataset.validate(dataset)

    assert [
             %Oban.Job{
               args: %{"resource_id" => ^gbfs_resource_id},
               worker: "Transport.Jobs.ResourceValidationJob",
               conflict?: false
             },
             %Oban.Job{
               args: %{
                 "first_job_args" => %{"resource_id" => ^gtfs_resource_id},
                 "jobs" => [
                   ["Elixir.Transport.Jobs.ResourceHistoryJob", %{}, %{}],
                   "Elixir.Transport.Jobs.ResourceHistoryValidationJob"
                 ]
               },
               worker: "Transport.Jobs.Workflow",
               conflict?: false
             }
           ] = all_enqueued()

    # Executing again does not create a conflict, even if the job has `unique` params
    Dataset.validate(dataset)

    assert [
             %Oban.Job{
               args: %{"resource_id" => ^gbfs_resource_id},
               worker: "Transport.Jobs.ResourceValidationJob",
               conflict?: false
             },
             %Oban.Job{
               args: %{
                 "first_job_args" => %{"resource_id" => gtfs_resource_id},
                 "jobs" => [
                   ["Elixir.Transport.Jobs.ResourceHistoryJob", %{}, %{}],
                   "Elixir.Transport.Jobs.ResourceHistoryValidationJob"
                 ]
               },
               worker: "Transport.Jobs.Workflow",
               conflict?: false
             },
             %Oban.Job{
               args: %{"resource_id" => ^gbfs_resource_id},
               worker: "Transport.Jobs.ResourceValidationJob",
               conflict?: false
             },
             %Oban.Job{
               args: %{
                 "first_job_args" => %{"resource_id" => gtfs_resource_id},
                 "jobs" => [
                   ["Elixir.Transport.Jobs.ResourceHistoryJob", %{}, %{}],
                   "Elixir.Transport.Jobs.ResourceHistoryValidationJob"
                 ]
               },
               worker: "Transport.Jobs.Workflow",
               conflict?: false
             }
           ] = all_enqueued()
  end

  test "get resources related files (GeoJSON, NeTEx,...)" do
    %{id: dataset_id} = insert(:dataset)

    r1 = insert(:resource, dataset_id: dataset_id)
    r2 = insert(:resource, dataset_id: dataset_id)
    r3 = insert(:resource, dataset_id: dataset_id)

    insert(:resource_history,
      resource_id: r1.id,
      payload: %{"uuid" => uuid1 = Ecto.UUID.generate()},
      last_up_to_date_at: dt1 = DateTime.utc_now()
    )

    insert(:resource_history,
      resource_id: r2.id,
      payload: %{"uuid" => uuid2 = Ecto.UUID.generate()},
      last_up_to_date_at: dt2 = DateTime.utc_now()
    )

    insert(:data_conversion,
      resource_history_uuid: uuid1,
      convert_from: "GTFS",
      convert_to: "GeoJSON",
      payload: %{"permanent_url" => "url1", "filesize" => "size1"}
    )

    insert(:data_conversion,
      resource_history_uuid: uuid1,
      convert_from: "GTFS",
      convert_to: "NeTEx",
      payload: %{"permanent_url" => "url11", "filesize" => "size11"}
    )

    insert(:data_conversion,
      resource_history_uuid: uuid2,
      convert_from: "GTFS",
      convert_to: "GeoJSON",
      payload: %{"permanent_url" => "url2", "filesize" => "size2"}
    )

    dataset = DB.Dataset |> preload(:resources) |> DB.Repo.get(dataset_id)

    related_resources = DB.Dataset.get_resources_related_files(dataset)

    assert %{
             r1.id => %{
               geojson: %{
                 url: "url1",
                 filesize: "size1",
                 resource_history_last_up_to_date_at: dt1
               },
               netex: %{
                 url: "url11",
                 filesize: "size11",
                 resource_history_last_up_to_date_at: dt1
               }
             },
             r2.id => %{
               geojson: %{
                 url: "url2",
                 filesize: "size2",
                 resource_history_last_up_to_date_at: dt2
               },
               netex: nil
             },
             r3.id => %{geojson: nil, netex: nil}
           } == related_resources
  end

  test "count dataset by mode" do
    insert(:region, id: 14, nom: "France")
    region = insert(:region)

    %{dataset: dataset} = insert_resource_and_friends(Date.utc_today(), region_id: region.id, modes: ["bus"])
    insert_resource_and_friends(Date.utc_today(), dataset: dataset, modes: ["ski"])

    %{dataset: dataset_2} = insert_resource_and_friends(Date.utc_today(), region_id: 14, modes: ["bus"])
    insert_resource_and_friends(Date.utc_today(), dataset: dataset_2, modes: ["ski"])

    insert_resource_and_friends(Date.utc_today(), region_id: 14)

    assert DB.Dataset.count_by_mode("bus") == 2
    assert DB.Dataset.count_by_mode("ski") == 2
    # this counts national datasets (region id = 14) with bus resources
    assert DB.Dataset.count_coach() == 1
  end
end
